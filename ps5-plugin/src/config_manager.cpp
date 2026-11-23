#include "plugin_common.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <sys/stat.h>
#include <errno.h>

#if defined(PS5_ETAHEN_NATIVE_HOOKS)
/* Optional etaHEN / PS5 SDK title ID resolution hook */
extern "C" int sceSystemServiceGetAppId(int* app_id);
extern "C" int sceLncUtilGetAppTitleId(int app_id, char* title_id);
#endif

static void sanitize_title_id(char out[PS5T_TITLE_ID_LEN], const char* raw) {
    memset(out, 0, PS5T_TITLE_ID_LEN);
    if (!raw || raw[0] == '\0') {
        strncpy(out, "PPSA00000", PS5T_TITLE_ID_LEN - 1);
        return;
    }

    size_t w = 0;
    for (size_t i = 0; raw[i] != '\0' && w < (PS5T_TITLE_ID_LEN - 1); ++i) {
        unsigned char c = (unsigned char)raw[i];
        if (isalnum(c) || c == '_' || c == '-') {
            out[w++] = (char)toupper(c);
        }
    }
    if (w == 0) {
        strncpy(out, "PPSA00000", PS5T_TITLE_ID_LEN - 1);
    }
}

static void build_config_path(char* out_path, size_t cap, const char* title_id) {
    char safe[PS5T_TITLE_ID_LEN];
    sanitize_title_id(safe, title_id);
    snprintf(out_path, cap, "%s/%s.ini", PS5T_DATA_DIR, safe);
}

extern "C" void config_ensure_dirs(void) {
    mkdir(PS5T_DATA_DIR, 0777);
    mkdir(PS5T_FONTS_DIR, 0777);
}

extern "C" void config_detect_title_id(char out_title_id[PS5T_TITLE_ID_LEN]) {
    char raw[32];
    memset(raw, 0, sizeof(raw));

#if defined(PS5_ETAHEN_NATIVE_HOOKS)
    int app_id = 0;
    if (sceSystemServiceGetAppId(&app_id) == 0 && app_id > 0) {
        if (sceLncUtilGetAppTitleId(app_id, raw) == 0 && raw[0] != '\0') {
            sanitize_title_id(out_title_id, raw);
            return;
        }
    }
#endif

    /* Fallback: inspect PS5 app param file if accessible inside game sandbox */
    FILE* f = fopen("/app0/sce_sys/param.json", "rb");
    if (f) {
        char buf[1024];
        size_t n = fread(buf, 1, sizeof(buf) - 1, f);
        fclose(f);
        buf[n] = '\0';

        const char* key = strstr(buf, "\"titleId\"");
        if (key) {
            const char* colon = strchr(key, ':');
            if (colon) {
                const char* q1 = strchr(colon, '"');
                if (q1) {
                    const char* q2 = strchr(q1 + 1, '"');
                    if (q2 && (q2 - (q1 + 1)) > 0 && (size_t)(q2 - (q1 + 1)) < sizeof(raw)) {
                        memcpy(raw, q1 + 1, (size_t)(q2 - (q1 + 1)));
                        sanitize_title_id(out_title_id, raw);
                        return;
                    }
                }
            }
        }
    }

    sanitize_title_id(out_title_id, "PPSA00000");
}

extern "C" void config_set_defaults(ps5t_config_t* cfg, int32_t screen_w, int32_t screen_h) {
    if (!cfg) return;
    if (screen_w < 640) screen_w = 1920;
    if (screen_h < 360) screen_h = 1080;

    cfg->screen_w         = screen_w;
    cfg->screen_h         = screen_h;
    /* Default subtitle ROI: bottom-center 72% width, 16% height */
    cfg->roi_w            = (screen_w * 72) / 100;
    cfg->roi_h            = (screen_h * 16) / 100;
    cfg->roi_x            = (screen_w - cfg->roi_w) / 2;
    cfg->roi_y            = (screen_h * 78) / 100;
    cfg->overlay_offset_y = 0;
    cfg->net_pref         = (uint8_t)NET_PREF_AUTO;
    cfg->paused           = 0;
}

static void clamp_config(ps5t_config_t* cfg) {
    if (cfg->screen_w < 640) cfg->screen_w = 1920;
    if (cfg->screen_h < 360) cfg->screen_h = 1080;
    if (cfg->roi_w < 160) cfg->roi_w = 160;
    if (cfg->roi_h < 48)  cfg->roi_h = 48;
    if (cfg->roi_w > cfg->screen_w - 16) cfg->roi_w = cfg->screen_w - 16;
    if (cfg->roi_h > cfg->screen_h / 2)  cfg->roi_h = cfg->screen_h / 2;
    if (cfg->roi_x < 0) cfg->roi_x = 0;
    if (cfg->roi_y < 0) cfg->roi_y = 0;
    if (cfg->roi_x + cfg->roi_w > cfg->screen_w) cfg->roi_x = cfg->screen_w - cfg->roi_w;
    if (cfg->roi_y + cfg->roi_h > cfg->screen_h) cfg->roi_y = cfg->screen_h - cfg->roi_h;
    if (cfg->net_pref > (uint8_t)NET_PREF_WIFI) cfg->net_pref = (uint8_t)NET_PREF_AUTO;
}

extern "C" void config_load(ps5t_runtime_t* rt) {
    if (!rt) return;

    config_ensure_dirs();
    ps5t_config_t loaded;
    config_set_defaults(&loaded, 1920, 1080);

    char path[256];
    build_config_path(path, sizeof(path), rt->title_id);

    FILE* f = fopen(path, "r");
    if (f) {
        char line[128];
        while (fgets(line, sizeof(line), f)) {
            char key[48];
            int32_t val = 0;
            if (sscanf(line, "%47[^=]=%d", key, &val) == 2) {
                if (strcmp(key, "roi_x") == 0)                 loaded.roi_x = val;
                else if (strcmp(key, "roi_y") == 0)            loaded.roi_y = val;
                else if (strcmp(key, "roi_w") == 0)            loaded.roi_w = val;
                else if (strcmp(key, "roi_h") == 0)            loaded.roi_h = val;
                else if (strcmp(key, "overlay_offset_y") == 0) loaded.overlay_offset_y = val;
                else if (strcmp(key, "net_pref") == 0)         loaded.net_pref = (uint8_t)val;
                else if (strcmp(key, "paused") == 0)           loaded.paused = (uint8_t)(val ? 1 : 0);
            }
        }
        fclose(f);
    }

    clamp_config(&loaded);

    pthread_mutex_lock(&rt->cfg_mutex);
    rt->cfg = loaded;
    pthread_mutex_unlock(&rt->cfg_mutex);
}

extern "C" void config_save(const ps5t_runtime_t* rt) {
    if (!rt) return;
    config_ensure_dirs();

    char path[256];
    build_config_path(path, sizeof(path), rt->title_id);

    FILE* f = fopen(path, "w");
    if (!f) return;

    fprintf(f, "# PS5 Arabic Translator Per-Game Config (%s)\n", rt->title_id);
    fprintf(f, "roi_x=%d\n", rt->cfg.roi_x);
    fprintf(f, "roi_y=%d\n", rt->cfg.roi_y);
    fprintf(f, "roi_w=%d\n", rt->cfg.roi_w);
    fprintf(f, "roi_h=%d\n", rt->cfg.roi_h);
    fprintf(f, "overlay_offset_y=%d\n", rt->cfg.overlay_offset_y);
    fprintf(f, "net_pref=%u\n", (unsigned)rt->cfg.net_pref);
    fprintf(f, "paused=%u\n", (unsigned)rt->cfg.paused);
    fclose(f);
}
