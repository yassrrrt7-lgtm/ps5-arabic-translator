#include "plugin_common.h"

#include <string.h>
#include <stdlib.h>

/* Strictly static buffers: ZERO malloc/new inside the per-frame capture loop */
static uint8_t  s_gray_curr[PS5T_MAX_ROI_BYTES];
static uint8_t  s_gray_pending[PS5T_MAX_ROI_BYTES];
static uint8_t  s_gray_last_sent[PS5T_MAX_ROI_BYTES];

static uint16_t s_last_w = 0;
static uint16_t s_last_h = 0;
static uint64_t s_last_sample_ms = 0;
static uint32_t s_frame_counter = 0;
static uint8_t  s_stable_ticks = 0;
static bool     s_has_pending = false;
static bool     s_has_sent_once = false;

/* Tuning constants for subtitle change detection */
#define ROI_SAMPLE_INTERVAL_MS    100U  /* Check pixels every 100ms */
#define ROI_CHANGE_THRESHOLD_SAD  6U    /* Mean pixel delta triggering new subtitle */
#define ROI_STABLE_THRESHOLD_SAD  2U    /* Max delta between consecutive ticks to confirm fade-in done */
#define ROI_STABLE_REQUIRED_TICKS 1U    /* 1 stable tick (~100ms debounce) before transmit */

extern "C" void roi_capture_init(void) {
    memset(s_gray_curr, 0, sizeof(s_gray_curr));
    memset(s_gray_pending, 0, sizeof(s_gray_pending));
    memset(s_gray_last_sent, 0, sizeof(s_gray_last_sent));
    s_last_w = 0;
    s_last_h = 0;
    s_last_sample_ms = 0;
    s_frame_counter = 0;
    s_stable_ticks = 0;
    s_has_pending = false;
    s_has_sent_once = false;
}

/* Computes downscaled dimensions strictly <= 20 KB (PS5T_MAX_ROI_BYTES) & height <= 64px */
static void compute_scaled_dims(int32_t roi_w, int32_t roi_h, uint16_t* out_w, uint16_t* out_h) {
    int32_t target_h = roi_h;
    int32_t target_w = roi_w;

    if (target_h > 64) {
        target_w = (roi_w * 64) / roi_h;
        target_h = 64;
    }
    if (target_w < 32) target_w = 32;
    if (target_h < 16) target_h = 16;

    /* Enforce hard 20 KB cap */
    while ((target_w * target_h) > (int32_t)PS5T_MAX_ROI_BYTES && target_w > 32 && target_h > 16) {
        target_w = (target_w * 9) / 10;
        target_h = (target_h * 9) / 10;
    }

    *out_w = (uint16_t)target_w;
    *out_h = (uint16_t)target_h;
}

/* Fast integer mean absolute difference (sampled every 2 pixels for <0.05ms cost) */
static uint32_t compute_mean_abs_diff(const uint8_t* a, const uint8_t* b, uint32_t count) {
    if (count == 0) return 0;
    uint64_t sum = 0;
    uint32_t samples = 0;
    for (uint32_t i = 0; i < count; i += 2) {
        int32_t d = (int32_t)a[i] - (int32_t)b[i];
        sum += (uint32_t)(d < 0 ? -d : d);
        samples++;
    }
    return samples ? (uint32_t)(sum / samples) : 0;
}

/* Extracts ROI directly from game BGRA8888 framebuffer and downscales to 8-bit grayscale */
static void extract_gray8_roi(
    const uint8_t* fb_bgra,
    int32_t fb_w,
    int32_t fb_h,
    int32_t fb_stride,
    int32_t roi_x,
    int32_t roi_y,
    int32_t roi_w,
    int32_t roi_h,
    uint16_t dst_w,
    uint16_t dst_h
) {
    for (uint16_t y = 0; y < dst_h; ++y) {
        int32_t sy = roi_y + ((int32_t)y * roi_h) / (int32_t)dst_h;
        if (sy < 0) sy = 0;
        if (sy >= fb_h) sy = fb_h - 1;
        const uint8_t* src_row = fb_bgra + (size_t)sy * (size_t)fb_stride;
        uint8_t* dst_row = s_gray_curr + (size_t)y * (size_t)dst_w;

        for (uint16_t x = 0; x < dst_w; ++x) {
            int32_t sx = roi_x + ((int32_t)x * roi_w) / (int32_t)dst_w;
            if (sx < 0) sx = 0;
            if (sx >= fb_w) sx = fb_w - 1;

            const uint8_t* px = src_row + (size_t)sx * 4U;
            uint32_t b = px[0];
            uint32_t g = px[1];
            uint32_t r = px[2];
            dst_row[x] = (uint8_t)((r * 77U + g * 150U + b * 29U) >> 8);
        }
    }
}

extern "C" void roi_on_video_frame(
    ps5t_runtime_t* rt,
    const uint8_t* fb_bgra,
    int32_t fb_width,
    int32_t fb_height,
    int32_t fb_stride_bytes
) {
    if (!rt || !fb_bgra || fb_width <= 0 || fb_height <= 0 || fb_stride_bytes <= 0) {
        return;
    }

    /* Update live screen dimensions if game resolution changed */
    if (rt->cfg.screen_w != fb_width || rt->cfg.screen_h != fb_height) {
        pthread_mutex_lock(&rt->cfg_mutex);
        rt->cfg.screen_w = fb_width;
        rt->cfg.screen_h = fb_height;
        pthread_mutex_unlock(&rt->cfg_mutex);
    }

    /* Pause capture while user is adjusting ROI box or translation is paused */
    if (rt->edit_mode || rt->cfg.paused) {
        return;
    }

    uint64_t now = ps5t_now_ms();
    bool force = rt->force_refresh_next;
    if (!force && (now - s_last_sample_ms) < ROI_SAMPLE_INTERVAL_MS) {
        return;
    }
    s_last_sample_ms = now;

    /* Snapshot ROI rectangle safely */
    int32_t rx, ry, rw, rh;
    pthread_mutex_lock(&rt->cfg_mutex);
    rx = rt->cfg.roi_x;
    ry = rt->cfg.roi_y;
    rw = rt->cfg.roi_w;
    rh = rt->cfg.roi_h;
    pthread_mutex_unlock(&rt->cfg_mutex);

    uint16_t dst_w = 0, dst_h = 0;
    compute_scaled_dims(rw, rh, &dst_w, &dst_h);
    uint32_t total_bytes = (uint32_t)dst_w * (uint32_t)dst_h;
    if (total_bytes == 0 || total_bytes > PS5T_MAX_ROI_BYTES) {
        return;
    }

    extract_gray8_roi(fb_bgra, fb_width, fb_height, fb_stride_bytes, rx, ry, rw, rh, dst_w, dst_h);

    /* Dimension change or forced refresh -> transmit immediately */
    if (force || !s_has_sent_once || dst_w != s_last_w || dst_h != s_last_h) {
        rt->force_refresh_next = false;
        memcpy(s_gray_last_sent, s_gray_curr, total_bytes);
        s_last_w = dst_w;
        s_last_h = dst_h;
        s_has_sent_once = true;
        s_has_pending = false;
        s_stable_ticks = 0;

        uint8_t flags = force ? ROI_FLAG_FORCE_REFRESH : 0;
        net_send_roi_frame(rt, ++s_frame_counter, s_gray_curr, dst_w, dst_h, flags);
        return;
    }

    /* Check if ROI meaningfully changed compared to last sent frame */
    uint32_t diff_from_sent = compute_mean_abs_diff(s_gray_curr, s_gray_last_sent, total_bytes);
    if (diff_from_sent < ROI_CHANGE_THRESHOLD_SAD) {
        s_has_pending = false;
        s_stable_ticks = 0;
        return;
    }

    /* Debounce fade-in animations: confirm pixels stabilized across consecutive tick */
    if (!s_has_pending) {
        memcpy(s_gray_pending, s_gray_curr, total_bytes);
        s_has_pending = true;
        s_stable_ticks = 0;
        return;
    }

    uint32_t diff_from_pending = compute_mean_abs_diff(s_gray_curr, s_gray_pending, total_bytes);
    if (diff_from_pending <= ROI_STABLE_THRESHOLD_SAD) {
        s_stable_ticks++;
        if (s_stable_ticks >= ROI_STABLE_REQUIRED_TICKS) {
            memcpy(s_gray_last_sent, s_gray_curr, total_bytes);
            s_has_pending = false;
            s_stable_ticks = 0;
            net_send_roi_frame(rt, ++s_frame_counter, s_gray_curr, dst_w, dst_h, 0);
        }
    } else {
        /* Still fading/scrolling; update pending snapshot */
        memcpy(s_gray_pending, s_gray_curr, total_bytes);
        s_stable_ticks = 0;
    }
}
