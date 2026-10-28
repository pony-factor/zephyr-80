"""Compile the patched upstream RGB functions against simulated power events.

Usage: python3 tests/test_rgb_patches.py <patched-zmk-checkout>
This checks power policy and fade transitions; it does not replace a Zephyr build.
"""
from pathlib import Path
import subprocess
import sys
import tempfile


def function(source, signature):
    start = source.index(signature + ' {')
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end] + '\n'


PREAMBLE = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#define IS_ENABLED(x) (x)
#define CONFIG_ZMK_RGB_UNDERGLOW_EXT_POWER 1
#define CONFIG_ZMK_BATTERY_REPORTING 0
#define CONFIG_ZMK_RGB_UNDERGLOW_AUTO_OFF_IDLE 1
#define CONFIG_ZMK_RGB_UNDERGLOW_AUTO_OFF_USB 1
#define CONFIG_ZMK_SPLIT_ROLE_CENTRAL 1
#define UNDERGLOW_LAYER_ENABLED COMMUNITY
#define CONFIG_ZMK_RGB_UNDERGLOW_FADE_OFF_MS 1500
#define STRIP_NUM_PIXELS 2
#define K_NO_WAIT 0
#define K_MSEC(x) (x)
#define MIN(a,b) ((a)<(b)?(a):(b))
#define BIT(x) (1u << (x))
#define LOG_ERR(...)
#define LOG_DBG(...)
#define ZMK_ACTIVITY_ACTIVE 1
#define USB_DC_SUSPEND 2
struct k_work { int unused; };
struct k_work_delayable { struct k_work work; void (*handler)(struct k_work *); };
#define K_WORK_DELAYABLE_DEFINE(name, fn) struct k_work_delayable name = {.handler = fn}
#define K_WORK_DEFINE(name, fn) struct k_work name
static int schedule_result;
static int k_work_reschedule_for_queue(void *queue, struct k_work_delayable *work, int delay) { return schedule_result; }
static void k_work_cancel_delayable(struct k_work_delayable *work) {}
static void *zmk_workqueue_lowprio_work_q(void) { return 0; }
static void k_timer_start(void *timer, int initial, int period) {}
static void k_timer_stop(void *timer) {}
static int underglow_tick;
struct led_rgb { uint8_t r, g, b; };
static struct led_rgb pixels[STRIP_NUM_PIXELS];
static struct { bool on, status_active, layer_enabled; int animation_step; int current_effect; } state;
static void *led_strip = (void *)1;
static void *ext_power = (void *)1;
static bool powered;
static int writes, layer_refreshes;
static int ext_power_get(void *device) { return powered; }
static int ext_power_enable(void *device) { powered = true; return 0; }
static int ext_power_disable(void *device) { powered = false; return 0; }
static void zmk_led_write_pixels(void) { writes++; }
static int zmk_rgb_underglow_save_state(void) { return 0; }
static int zmk_rgb_underglow_transient_on(void);
static int zmk_rgb_underglow_transient_off(void);
#define UNDERGLOW_EFFECT_LAYER_INDICATORS 4
static void zmk_rgb_underglow_set_layer(uint8_t layer, bool wakeup) { layer_refreshes++; zmk_rgb_underglow_transient_on(); }
static uint8_t rgb_underglow_top_layer(void) { return 0; }
static bool activity_active = true, usb_powered = true;
static int usb_status;
static int zmk_activity_get_state(void) { return activity_active ? 1 : 0; }
static bool zmk_usb_is_powered(void) { return usb_powered; }
static int zmk_usb_get_status(void) { return usb_status; }
typedef struct { int type; uint32_t layers; bool wakeup; } zmk_event_t;
struct zmk_split_peripheral_layer_changed { uint32_t layers; };
struct zmk_underglow_color_changed { uint32_t layers; bool wakeup; };
static const void *as_zmk_activity_state_changed(const zmk_event_t *e) { return e->type == 1 ? e : 0; }
static const void *as_zmk_usb_conn_state_changed(const zmk_event_t *e) { return e->type == 2 ? e : 0; }
static const struct zmk_split_peripheral_layer_changed *as_zmk_split_peripheral_layer_changed(const zmk_event_t *e) {
    static struct zmk_split_peripheral_layer_changed event;
    event.layers = e->layers; return e->type == 3 ? &event : 0;
}
static const struct zmk_underglow_color_changed *as_zmk_underglow_color_changed(const zmk_event_t *e) {
    static struct zmk_underglow_color_changed event;
    event.layers = e->layers; event.wakeup = e->wakeup; return e->type == 4 ? &event : 0;
}
static void k_work_submit_to_queue(void *queue, struct k_work *work);
'''

SCENARIOS = r'''
static void k_work_submit_to_queue(void *queue, struct k_work *work) {
#if !CONFIG_ZMK_RGB_UNDERGLOW_FADE_OFF
    zmk_rgb_underglow_off_handler(work);
#endif
}
static void finish_fade(void) {
#if CONFIG_ZMK_RGB_UNDERGLOW_FADE_OFF
    for (int frame = 0; frame < 60; frame++) zmk_rgb_underglow_fade_off_handler(0);
#endif
}
int main(void) {
    state.on = true; powered = true; state.current_effect = 2;
    pixels[0] = (struct led_rgb){240, 120, 60};
    pixels[1] = (struct led_rgb){0, 210, 30};
    assert(zmk_rgb_underglow_off() == 0);
    assert(!state.on);
#if CONFIG_ZMK_RGB_UNDERGLOW_FADE_OFF
    assert(powered);
    zmk_rgb_underglow_fade_off_handler(0);
    assert(pixels[0].r < 240 && pixels[0].r > 0);
    assert(pixels[0].g < 120 && pixels[0].b < 60);
    assert(pixels[1].r == 0); // No new color components are introduced.
    finish_fade();
#endif
    assert(!powered);
    for (int i=0;i<STRIP_NUM_PIXELS;i++) assert(!pixels[i].r && !pixels[i].g && !pixels[i].b);
    assert(state.current_effect == 2);
    zmk_rgb_underglow_on();
    pixels[0] = (struct led_rgb){200, 100, 50};
    zmk_rgb_underglow_off();
    zmk_rgb_underglow_on();
#if CONFIG_ZMK_RGB_UNDERGLOW_FADE_OFF
    int before = writes;
    zmk_rgb_underglow_fade_off_handler(0);
    assert(writes == before && powered && state.on); // Wake cancels the pending fade.
    schedule_result = -1;
    zmk_rgb_underglow_off();
    assert(!powered && !pixels[0].r); // Scheduling failure still switches off safely.
    schedule_result = 0;
    zmk_rgb_underglow_on();
#endif
    // Every combination of idle, USB power and suspend policy inputs.
    for (int active=0;active<2;active++) for(int usb=0;usb<2;usb++) for(int suspended=0;suspended<2;suspended++) {
        activity_active=active;usb_powered=usb;usb_status=suspended?USB_DC_SUSPEND:0;
        assert(rgb_underglow_should_be_awake() == (active && usb && (!CONFIG_ZMK_RGB_UNDERGLOW_AUTO_OFF_USB_SUSPEND || !suspended)));
    }
    activity_active=true;usb_powered=true;usb_status=0;
    state.on=true;powered=true;
    usb_status=USB_DC_SUSPEND;
    zmk_event_t usb_event={.type=2};
    assert(rgb_underglow_event_listener(&usb_event)==0);
#if CONFIG_ZMK_RGB_UNDERGLOW_AUTO_OFF_USB_SUSPEND
    assert(!state.on);
    finish_fade();assert(!powered);
    #if COMMUNITY
    state.layer_enabled=true;
    int refresh_before=layer_refreshes;
    zmk_event_t layer_event={.type=3,.layers=1};
    zmk_event_t color_event={.type=4,.layers=1,.wakeup=true};
    rgb_underglow_event_listener(&layer_event);
    rgb_underglow_event_listener(&color_event);
    assert(layer_refreshes==refresh_before && !state.on);
    state.layer_enabled=false;
    #endif
    usb_status=0;rgb_underglow_event_listener(&usb_event);
    assert(state.on && powered); // Resume restores previously-on lighting.
    zmk_rgb_underglow_off();finish_fade();
    usb_status=USB_DC_SUSPEND;rgb_underglow_event_listener(&usb_event);
    usb_status=0;rgb_underglow_event_listener(&usb_event);
    assert(!state.on); // Resume preserves a user's already-off state.
#else
    assert(state.on); // Suspend has no effect when disabled.
#endif
    return 0;
}
'''


def main():
    zmk = Path(sys.argv[1])
    source = (zmk / 'app/src/rgb_underglow.c').read_text()
    community = 'int zmk_rgb_underglow_transient_on(void) {' in source
    state_block = source.split('static struct rgb_underglow_state state;\n\n', 1)[1].split('#if IS_ENABLED(CONFIG_ZMK_RGB_UNDERGLOW_EXT_POWER)', 1)[0]
    helpers = source[source.index('#if IS_ENABLED(CONFIG_ZMK_RGB_UNDERGLOW_FADE_OFF)\nstatic void zmk_rgb_underglow_finish_off'):source.index('int zmk_rgb_underglow_on(void) {')]
    power = function(source, 'void zmk_rgb_set_ext_power(void)')
    transitions = source[source.index('int zmk_rgb_underglow_on(void) {'):source.index('int zmk_rgb_underglow_calc_effect(int direction) {')]
    # Match upstream external linkage for the community transient functions.
    preamble = PREAMBLE.replace('static int zmk_rgb_underglow_transient_', 'int zmk_rgb_underglow_transient_')
    sleep = source[source.index('struct rgb_underglow_sleep_state {'):source.index('static int rgb_underglow_event_listener(const zmk_event_t *eh) {')]
    listener = function(source, 'static int rgb_underglow_event_listener(const zmk_event_t *eh)')
    code = preamble + state_block + power + helpers + transitions + sleep + listener + SCENARIOS
    compiler_flags = ['-Wno-gnu-designator'] if 'clang' in subprocess.check_output(['cc', '--version'], text=True).lower() else []
    with tempfile.TemporaryDirectory(prefix='glove80-rgb-test-') as temporary:
        root = Path(temporary)
        harness = root / 'test.c'
        harness.write_text(code)
        for fade in (0, 1):
            for suspend in (0, 1):
                binary = root / f'test-{fade}-{suspend}'
                subprocess.run(['cc', '-std=c11', '-Wall', '-Werror', '-Wno-unused-function', '-Wno-unused-variable', *compiler_flags,
                    f'-DCOMMUNITY={int(community)}', f'-DCONFIG_ZMK_RGB_UNDERGLOW_FADE_OFF={fade}',
                    f'-DCONFIG_ZMK_RGB_UNDERGLOW_AUTO_OFF_USB_SUSPEND={suspend}', str(harness), '-o', str(binary)], check=True)
                subprocess.run([str(binary)], check=True)
    print('RGB transition tests passed (' + ('community-rgb' if community else 'stock') + '): fade, wake cancellation, power-off fallback, policy gates, suspend/resume, and off-state preservation')


if __name__ == '__main__':
    main()
