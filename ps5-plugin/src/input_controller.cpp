#include "plugin_common.h"
#include <stdlib.h>

/* Standard PS5 ScePadButtonDataOffset bitmasks */
#define PAD_BTN_L1        0x00000400U
#define PAD_BTN_R1        0x00000800U
#define PAD_BTN_TRIANGLE  0x00001000U
#define PAD_BTN_CIRCLE    0x00002000U
#define PAD_BTN_CROSS     0x00004000U
#define PAD_BTN_SQUARE    0x00008000U
#define PAD_BTN_TOUCHPAD  0x00100000U

#define PAD_EDIT_COMBO    (PAD_BTN_L1 | PAD_BTN_R1 | PAD_BTN_TOUCHPAD)

static uint32_t s_prev_buttons = 0;
static uint64_t s_last_combo_toggle_ms = 0;

static int32_t stick_delta(uint8_t axis_raw, int32_t speed_px) {
    int32_t centered = (int32_t)axis_raw - 128;
    const int32_t deadzone = 22;
    if (centered > -deadzone && centered < deadzone) {
        return 0;
    }
    return (centered * speed_px) / 106;
}

extern "C" void input_init(void) {
    s_prev_buttons = 0;
    s_last_combo_toggle_ms = 0;
}

extern "C" void input_process_pad(ps5t_runtime_t* rt, const ps5t_pad_state_t* pad) {
    if (!rt || !pad) return;

    uint32_t btns = pad->buttons;
    uint32_t newly_pressed = btns & (~s_prev_buttons);
    uint64_t now = ps5t_now_ms();

    /* Toggle Edit Mode on L1 + R1 + Touchpad (debounced 400ms) */
    bool combo_held = ((btns & PAD_EDIT_COMBO) == PAD_EDIT_COMBO);
    bool combo_was_held = ((s_prev_buttons & PAD_EDIT_COMBO) == PAD_EDIT_COMBO);
    if (combo_held && !combo_was_held && (now - s_last_combo_toggle_ms) > 400) {
        s_last_combo_toggle_ms = now;
        bool entering = !rt->edit_mode;
        rt->edit_mode = entering;
        if (!entering) {
            pthread_mutex_lock(&rt->cfg_mutex);
            config_save(rt);
            pthread_mutex_unlock(&rt->cfg_mutex);
            rt->force_refresh_next = true;
        }
        s_prev_buttons = btns;
        return;
    }

    if (!rt->edit_mode) {
        s_prev_buttons = btns;
        return;
    }

    /* Edit Mode active: manipulate ROI box smoothly via DualSense sticks & buttons */
    pthread_mutex_lock(&rt->cfg_mutex);

    int32_t dx = stick_delta(pad->lx, 10);
    int32_t dy = stick_delta(pad->ly, 10);
    int32_t dw = stick_delta(pad->rx, 10);
    int32_t dh = stick_delta(pad->ry, 8);

    rt->cfg.roi_x += dx;
    rt->cfg.roi_y += dy;
    rt->cfg.roi_w += dw;
    rt->cfg.roi_h += dh;

    /* Keep ROI inside valid screen bounds */
    if (rt->cfg.roi_w < 160) rt->cfg.roi_w = 160;
    if (rt->cfg.roi_h < 48)  rt->cfg.roi_h = 48;
    if (rt->cfg.roi_w > rt->cfg.screen_w - 16) rt->cfg.roi_w = rt->cfg.screen_w - 16;
    if (rt->cfg.roi_h > rt->cfg.screen_h / 2)  rt->cfg.roi_h = rt->cfg.screen_h / 2;

    if (rt->cfg.roi_x < 0) rt->cfg.roi_x = 0;
    if (rt->cfg.roi_y < 0) rt->cfg.roi_y = 0;
    if (rt->cfg.roi_x + rt->cfg.roi_w > rt->cfg.screen_w) {
        rt->cfg.roi_x = rt->cfg.screen_w - rt->cfg.roi_w;
    }
    if (rt->cfg.roi_y + rt->cfg.roi_h > rt->cfg.screen_h) {
        rt->cfg.roi_y = rt->cfg.screen_h - rt->cfg.roi_h;
    }

    /* Triangle: Toggle Pause Translation ON/OFF */
    if (newly_pressed & PAD_BTN_TRIANGLE) {
        rt->cfg.paused = rt->cfg.paused ? 0 : 1;
        if (!rt->cfg.paused) {
            rt->force_refresh_next = true;
        }
    }

    /* Square: Cycle Connection Mode (Auto -> Force LAN 10.0.0.2 -> Force Wi-Fi) */
    if (newly_pressed & PAD_BTN_SQUARE) {
        rt->cfg.net_pref = (uint8_t)((rt->cfg.net_pref + 1) % 3);
    }

    /* Cross: Save per-game config & exit Edit Mode */
    if (newly_pressed & PAD_BTN_CROSS) {
        config_save(rt);
        rt->edit_mode = false;
        rt->force_refresh_next = true;
    }

    pthread_mutex_unlock(&rt->cfg_mutex);
    s_prev_buttons = btns;
}

#if defined(PS5_ETAHEN_NATIVE_HOOKS)
/*
 * Real PS5 5.50 hook integration point:
 * When detoured onto `scePadReadState(int32_t handle, ScePadData* pData)`,
 * copy `pData->buttons`, `leftStick`, `rightStick` into `ps5t_pad_state_t`,
 * call `input_process_pad(g_rt, &snap)`, and if `g_rt->edit_mode` is true,
 * zero out `pData->buttons` and center sticks so the game ignores Edit Mode inputs.
 */
#endif

extern "C" void input_poll_fallback(ps5t_runtime_t* rt) {
    (void)rt;
    /* Intentionally no-op when pad input is driven by the scePadReadState hook */
}
