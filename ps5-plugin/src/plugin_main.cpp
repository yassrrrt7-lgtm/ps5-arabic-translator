#include "plugin_common.h"

#include <string.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>

/* Statically allocated global runtime (<1MB total memory footprint) */
static ps5t_runtime_t g_rt;
static pthread_t      g_worker_thread;
static bool           g_initialized = false;

extern "C" uint64_t ps5t_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)(ts.tv_nsec / 1000000ULL);
}

static void* translator_worker_thread(void* arg) {
    ps5t_runtime_t* rt = (ps5t_runtime_t*)arg;

    while (rt->running) {
        net_tick(rt);
        net_poll_incoming(rt);
        input_poll_fallback(rt);
        usleep(10000); /* 10ms tick -> negligible CPU usage, instant UDP RX */
    }
    return NULL;
}

/* Public hook entry called from hooked sceVideoOutSubmitFlip on PS5 5.50 */
extern "C" void ps5_translator_on_flip(
    uint8_t* fb_bgra,
    int32_t fb_width,
    int32_t fb_height,
    int32_t fb_stride_bytes
) {
    if (!g_initialized || !g_rt.running) return;
    roi_on_video_frame(&g_rt, fb_bgra, fb_width, fb_height, fb_stride_bytes);
    overlay_render_frame(&g_rt, fb_bgra, fb_width, fb_height, fb_stride_bytes);
}

/* Public hook entry called from hooked scePadReadState on PS5 5.50 */
extern "C" bool ps5_translator_on_pad(const ps5t_pad_state_t* pad) {
    if (!g_initialized || !g_rt.running || !pad) return false;
    input_process_pad(&g_rt, pad);
    return g_rt.edit_mode; /* true => caller should mask game inputs while editing ROI */
}

extern "C" int ps5_translator_start(void) {
    if (g_initialized) return 0;

    memset(&g_rt, 0, sizeof(g_rt));
    pthread_mutex_init(&g_rt.cfg_mutex, NULL);

    config_detect_title_id(g_rt.title_id);
    config_load(&g_rt);

    input_init();
    roi_capture_init();
    overlay_init();
    net_init();

    g_rt.running = true;
    g_rt.edit_mode = false;
    g_rt.force_refresh_next = true;

    if (pthread_create(&g_worker_thread, NULL, translator_worker_thread, &g_rt) != 0) {
        g_rt.running = false;
        net_shutdown();
        overlay_shutdown();
        pthread_mutex_destroy(&g_rt.cfg_mutex);
        return -1;
    }

    g_initialized = true;
    return 0;
}

extern "C" int ps5_translator_stop(void) {
    if (!g_initialized) return 0;

    g_rt.running = false;
    pthread_join(g_worker_thread, NULL);

    pthread_mutex_lock(&g_rt.cfg_mutex);
    config_save(&g_rt);
    pthread_mutex_unlock(&g_rt.cfg_mutex);

    net_shutdown();
    overlay_shutdown();
    pthread_mutex_destroy(&g_rt.cfg_mutex);
    g_initialized = false;
    return 0;
}

/* Standard PS5 PRX / etaHEN Plugin Loader lifecycle symbols */
extern "C" int module_start(size_t argc, const void* args) {
    (void)argc;
    (void)args;
    return ps5_translator_start();
}

extern "C" int module_stop(size_t argc, const void* args) {
    (void)argc;
    (void)args;
    return ps5_translator_stop();
}

/* Standalone / ELF test entrypoint guard */
#if defined(PS5_BUILD_STANDALONE_ELF)
int main(void) {
    if (ps5_translator_start() != 0) {
        return 1;
    }
    while (g_rt.running) {
        sleep(1);
    }
    return 0;
}
#endif
