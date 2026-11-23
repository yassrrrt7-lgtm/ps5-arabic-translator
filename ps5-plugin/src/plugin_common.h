#ifndef PS5_TRANSLATOR_PLUGIN_COMMON_H
#define PS5_TRANSLATOR_PLUGIN_COMMON_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <pthread.h>
#include "../../shared-protocol/protocol.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Storage paths on PS5 internal SSD */
#define PS5T_DATA_DIR           "/data/ps5_translator"
#define PS5T_FONTS_DIR          "/data/ps5_translator/fonts"
#define PS5T_FONT_PRIMARY       "/data/ps5_translator/fonts/Cairo-Bold.ttf"
#define PS5T_FONT_FALLBACK      "/data/ps5_translator/fonts/NotoSansArabic-Bold.ttf"

/* Connection mode preference (cycled via Square in Edit Mode) */
typedef enum {
    NET_PREF_AUTO = 0, /* Prioritize Direct LAN 10.0.0.2, auto-fallback to Wi-Fi */
    NET_PREF_LAN  = 1, /* Force Direct Ethernet LAN (10.0.0.2) only */
    NET_PREF_WIFI = 2  /* Force Wi-Fi auto-discovery only */
} ps5t_net_pref_t;

/* Per-game saved ROI & overlay configuration */
typedef struct {
    int32_t  roi_x;
    int32_t  roi_y;
    int32_t  roi_w;
    int32_t  roi_h;
    int32_t  overlay_offset_y;
    uint8_t  net_pref;      /* ps5t_net_pref_t */
    uint8_t  paused;        /* 1 = translation paused */
    int32_t  screen_w;
    int32_t  screen_h;
} ps5t_config_t;

/* Double-buffered thread-safe translation display state (zero lock contention on render) */
typedef struct {
    char     utf8_buf[2][PS5T_MAX_UTF8_BYTES + 1];
    volatile int active_idx;
    uint32_t last_frame_id;
    uint16_t last_seq_num;
    uint16_t last_latency_ms;
    uint8_t  is_cache_hit;
    uint8_t  is_clear;
    uint8_t  active_transport; /* ps5t_transport_t */
    uint8_t  server_ready;
    uint8_t  thermal_warn;
} ps5t_display_state_t;

/* Simplified DualSense controller snapshot (matches ScePadData layout fields) */
typedef struct {
    uint32_t buttons;
    uint8_t  lx; /* 0..255, center ~128 */
    uint8_t  ly; /* 0..255, center ~128 */
    uint8_t  rx; /* 0..255, center ~128 */
    uint8_t  ry; /* 0..255, center ~128 */
} ps5t_pad_state_t;

/* Global plugin runtime context (statically allocated, <1MB RAM footprint) */
typedef struct {
    volatile bool        running;
    volatile bool        edit_mode;
    volatile bool        force_refresh_next;
    char                 title_id[PS5T_TITLE_ID_LEN];
    ps5t_config_t        cfg;
    ps5t_display_state_t display;
    pthread_mutex_t      cfg_mutex;
} ps5t_runtime_t;

/* Monotonic clock helper (milliseconds) */
uint64_t ps5t_now_ms(void);

/* Module APIs */
void config_ensure_dirs(void);
void config_detect_title_id(char out_title_id[PS5T_TITLE_ID_LEN]);
void config_set_defaults(ps5t_config_t* cfg, int32_t screen_w, int32_t screen_h);
void config_load(ps5t_runtime_t* rt);
void config_save(const ps5t_runtime_t* rt);

void input_init(void);
void input_process_pad(ps5t_runtime_t* rt, const ps5t_pad_state_t* pad);
void input_poll_fallback(ps5t_runtime_t* rt);

bool net_init(void);
void net_shutdown(void);
void net_tick(ps5t_runtime_t* rt);
void net_poll_incoming(ps5t_runtime_t* rt);
bool net_send_roi_frame(
    ps5t_runtime_t* rt,
    uint32_t frame_id,
    const uint8_t* gray_pixels,
    uint16_t width,
    uint16_t height,
    uint8_t flags
);

void roi_capture_init(void);
void roi_on_video_frame(
    ps5t_runtime_t* rt,
    const uint8_t* fb_bgra,
    int32_t fb_width,
    int32_t fb_height,
    int32_t fb_stride_bytes
);

/* Overlay hooks (implemented in Script 5 inside ps5-plugin/src/overlay/) */
bool overlay_init(void);
void overlay_shutdown(void);
void overlay_render_frame(
    const ps5t_runtime_t* rt,
    uint8_t* fb_bgra,
    int32_t fb_width,
    int32_t fb_height,
    int32_t fb_stride_bytes
);

#ifdef __cplusplus
}
#endif

#endif /* PS5_TRANSLATOR_PLUGIN_COMMON_H */
