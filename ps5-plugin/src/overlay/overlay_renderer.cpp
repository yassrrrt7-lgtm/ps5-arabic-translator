#include "../plugin_common.h"
#include "arabic_font_atlas.h"

#include <stdio.h>
#include <string.h>

static inline void blend_pixel_bgra(uint8_t* dst, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    if (a == 0) return;
    if (a == 255) {
        dst[0] = b;
        dst[1] = g;
        dst[2] = r;
        dst[3] = 255;
        return;
    }
    uint32_t inv = 255U - (uint32_t)a;
    dst[0] = (uint8_t)(((uint32_t)b * a + (uint32_t)dst[0] * inv) >> 8);
    dst[1] = (uint8_t)(((uint32_t)g * a + (uint32_t)dst[1] * inv) >> 8);
    dst[2] = (uint8_t)(((uint32_t)r * a + (uint32_t)dst[2] * inv) >> 8);
    dst[3] = 255;
}

static void draw_filled_rect(
    uint8_t* fb, int32_t fb_w, int32_t fb_h, int32_t stride,
    int32_t x, int32_t y, int32_t w, int32_t h,
    uint8_t r, uint8_t g, uint8_t b, uint8_t a
) {
    if (w <= 0 || h <= 0) return;
    int32_t x0 = x < 0 ? 0 : x;
    int32_t y0 = y < 0 ? 0 : y;
    int32_t x1 = (x + w) > fb_w ? fb_w : (x + w);
    int32_t y1 = (y + h) > fb_h ? fb_h : (y + h);

    for (int32_t py = y0; py < y1; ++py) {
        uint8_t* row = fb + (size_t)py * (size_t)stride;
        for (int32_t px = x0; px < x1; ++px) {
            blend_pixel_bgra(row + (size_t)px * 4U, r, g, b, a);
        }
    }
}

static void draw_border_rect(
    uint8_t* fb, int32_t fb_w, int32_t fb_h, int32_t stride,
    int32_t x, int32_t y, int32_t w, int32_t h, int32_t thickness,
    uint8_t r, uint8_t g, uint8_t b, uint8_t a
) {
    draw_filled_rect(fb, fb_w, fb_h, stride, x, y, w, thickness, r, g, b, a);
    draw_filled_rect(fb, fb_w, fb_h, stride, x, y + h - thickness, w, thickness, r, g, b, a);
    draw_filled_rect(fb, fb_w, fb_h, stride, x, y, thickness, h, r, g, b, a);
    draw_filled_rect(fb, fb_w, fb_h, stride, x + w - thickness, y, thickness, h, r, g, b, a);
}

static void draw_utf8_line(
    uint8_t* fb, int32_t fb_w, int32_t fb_h, int32_t stride,
    const char* utf8_line, int32_t byte_len,
    int32_t start_x, int32_t baseline_y,
    uint8_t r, uint8_t g, uint8_t b
) {
    if (!font_atlas_is_ready() || !utf8_line || byte_len <= 0) return;

    int32_t atlas_w = 0, atlas_h = 0;
    const uint8_t* atlas = font_atlas_bitmap(&atlas_w, &atlas_h);

    const char* p = utf8_line;
    const char* end = utf8_line + byte_len;
    int32_t pen_x = start_x;

    while (p < end && *p) {
        uint32_t cp = font_utf8_next(&p);
        const ps5t_glyph_t* gl = font_atlas_get_glyph(cp);
        if (!gl) continue;

        if (gl->w > 0 && gl->h > 0) {
            int32_t gx = pen_x + gl->xoff;
            int32_t gy = baseline_y + gl->yoff;

            for (int32_t row = 0; row < (int32_t)gl->h; ++row) {
                int32_t py = gy + row;
                if (py < 0 || py >= fb_h) continue;
                uint8_t* fb_row = fb + (size_t)py * (size_t)stride;
                const uint8_t* a_row = atlas + (size_t)(gl->atlas_y + row) * (size_t)atlas_w + gl->atlas_x;

                for (int32_t col = 0; col < (int32_t)gl->w; ++col) {
                    int32_t px = gx + col;
                    if (px < 0 || px >= fb_w) continue;
                    uint8_t alpha = a_row[col];
                    if (alpha > 8) {
                        blend_pixel_bgra(fb_row + (size_t)px * 4U, r, g, b, alpha);
                    }
                }
            }
        }
        pen_x += gl->xadvance;
    }
}

extern "C" bool overlay_init(void) {
    return font_atlas_init(PS5T_FONT_PRIMARY, PS5T_FONT_FALLBACK, 34.0f);
}

extern "C" void overlay_shutdown(void) {
    font_atlas_shutdown();
}

static void render_edit_mode(
    const ps5t_runtime_t* rt,
    uint8_t* fb, int32_t fb_w, int32_t fb_h, int32_t stride
) {
    int32_t rx = rt->cfg.roi_x;
    int32_t ry = rt->cfg.roi_y;
    int32_t rw = rt->cfg.roi_w;
    int32_t rh = rt->cfg.roi_h;

    /* Subtle cyan tint + crisp 3px cyan border around ROI capture area */
    draw_filled_rect(fb, fb_w, fb_h, stride, rx, ry, rw, rh, 0, 210, 255, 36);
    draw_border_rect(fb, fb_w, fb_h, stride, rx, ry, rw, rh, 3, 0, 230, 255, 240);

    /* Status & DualSense Legend bar directly above the ROI */
    int32_t bar_h = 84;
    int32_t bar_y = (ry - bar_h - 8 >= 8) ? (ry - bar_h - 8) : (ry + rh + 8);
    draw_filled_rect(fb, fb_w, fb_h, stride, rx, bar_y, rw, bar_h, 10, 14, 22, 220);
    draw_border_rect(fb, fb_w, fb_h, stride, rx, bar_y, rw, bar_h, 2, 0, 200, 255, 200);

    const char* net_pref_str = (rt->cfg.net_pref == NET_PREF_LAN) ? "LAN" :
                               (rt->cfg.net_pref == NET_PREF_WIFI) ? "WIFI" : "AUTO";
    const char* active_str   = (rt->display.active_transport == TRANSPORT_LAN) ? "LAN 10.0.0.2" :
                               (rt->display.active_transport == TRANSPORT_WIFI) ? "WIFI" : "WAITING";

    char info_line1[160];
    snprintf(info_line1, sizeof(info_line1),
             "EDIT ROI [%s] X:%d Y:%d W:%d H:%d | NET:%s (%s) | %s",
             rt->title_id, rx, ry, rw, rh, net_pref_str, active_str,
             rt->cfg.paused ? "PAUSED" : "LIVE");

    const char* info_line2 = "L-Stick: Move | R-Stick: Resize | X: Save | Tri: Pause | Sq: Net Mode";

    if (font_atlas_is_ready()) {
        int32_t asc = font_atlas_ascent();
        draw_utf8_line(fb, fb_w, fb_h, stride, info_line1, (int32_t)strlen(info_line1),
                       rx + 14, bar_y + asc + 6, 0, 240, 255);
        draw_utf8_line(fb, fb_w, fb_h, stride, info_line2, (int32_t)strlen(info_line2),
                       rx + 14, bar_y + asc + font_atlas_line_height() + 8, 235, 235, 235);
    }
}

extern "C" void overlay_render_frame(
    const ps5t_runtime_t* rt,
    uint8_t* fb_bgra,
    int32_t fb_width,
    int32_t fb_height,
    int32_t fb_stride_bytes
) {
    if (!rt || !fb_bgra || fb_width <= 0 || fb_height <= 0 || fb_stride_bytes <= 0) {
        return;
    }

    if (rt->edit_mode) {
        render_edit_mode(rt, fb_bgra, fb_width, fb_height, fb_stride_bytes);
        return;
    }

    if (rt->cfg.paused || rt->display.is_clear) {
        return;
    }

    int idx = rt->display.active_idx;
    const char* text = rt->display.utf8_buf[idx];
    if (!text || text[0] == '\0' || !font_atlas_is_ready()) {
        return;
    }

    /* Split up to 3 pre-wrapped lines (already shaped & BiDi-reordered by iPhone) */
    const char* line_ptrs[3] = { NULL, NULL, NULL };
    int32_t     line_lens[3] = { 0, 0, 0 };
    int32_t     line_widths[3] = { 0, 0, 0 };
    int32_t     line_count = 0;
    int32_t     max_w = 0;

    const char* cur = text;
    while (*cur && line_count < 3) {
        const char* nl = strchr(cur, '\n');
        int32_t len = nl ? (int32_t)(nl - cur) : (int32_t)strlen(cur);
        if (len > 0) {
            int32_t w = font_atlas_measure_line(cur, len);
            line_ptrs[line_count] = cur;
            line_lens[line_count] = len;
            line_widths[line_count] = w;
            if (w > max_w) max_w = w;
            line_count++;
        }
        if (!nl) break;
        cur = nl + 1;
    }

    if (line_count == 0 || max_w <= 0) return;

    int32_t pad_x = 24;
    int32_t pad_y = 14;
    int32_t lh = font_atlas_line_height();
    int32_t box_w = max_w + pad_x * 2;
    int32_t box_h = line_count * lh + pad_y * 2;

    int32_t roi_center_x = rt->cfg.roi_x + (rt->cfg.roi_w / 2);
    int32_t box_x = roi_center_x - (box_w / 2);
    int32_t box_y = rt->cfg.roi_y + rt->cfg.overlay_offset_y + (rt->cfg.roi_h - box_h) / 2;

    if (box_x < 12) box_x = 12;
    if (box_x + box_w > fb_width - 12) box_x = fb_width - box_w - 12;
    if (box_y < 12) box_y = 12;
    if (box_y + box_h > fb_height - 12) box_y = fb_height - box_h - 12;

    /* Clean semi-transparent dark backdrop rgba(0, 0, 0, 0.72) */
    draw_filled_rect(fb_bgra, fb_width, fb_height, fb_stride_bytes,
                     box_x, box_y, box_w, box_h, 0, 0, 0, 184);

    /* Center each shaped Arabic line horizontally inside the backdrop */
    int32_t asc = font_atlas_ascent();
    for (int32_t i = 0; i < line_count; ++i) {
        int32_t lx = box_x + (box_w - line_widths[i]) / 2;
        int32_t ly = box_y + pad_y + asc + i * lh;
        draw_utf8_line(fb_bgra, fb_width, fb_height, fb_stride_bytes,
                       line_ptrs[i], line_lens[i], lx, ly, 255, 255, 255);
    }
}
