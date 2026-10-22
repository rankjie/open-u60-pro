#define _GNU_SOURCE
#include "lvgl_abi.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CHECK(condition, message) do { if (!(condition)) { \
    fprintf(stderr, "Native ABI failure: %s\n", message); return 1; \
} } while (0)
static unsigned flushes, clicks;
static native_obj *expected_target;
static int callback_valid = 1;
static unsigned marker;
static void clicked(native_event *event) {
    if (native_lvgl.event_target(event) != expected_target ||
        native_lvgl.event_code(event) != NATIVE_EVENT_CLICKED ||
        native_lvgl.event_user_data(event) != &marker) callback_valid = 0;
    clicks++;
}
static void flush(void *driver, const void *area, uint16_t *pixels) {
    (void)area; (void)pixels;
    flushes++;
    native_lvgl.flush_ready(driver);
}
static int probe_main(int argc, char **argv, char **env) {
    (void)argc; (void)argv; (void)env;
    CHECK(native_lvgl.default_display() == NULL, "display before initialization");
    native_lvgl.init();
    CHECK(native_lvgl.is_initialized(), "LVGL initialization");

    /* Driver sizes/offsets match this firmware's own initializer and register
     * disassembly. The flush callback acknowledges a memory buffer; it opens no
     * framebuffer, DRM or input devices. */
    static _Alignas(16) unsigned char driver[0x98], buffer[0x28];
    static uint16_t pixels[320 * 480];
    native_lvgl.driver_init(driver);
    native_lvgl.buffer_init(buffer, pixels, NULL, 320 * 480);
    void *buf = buffer;
    memcpy(driver + 0x10, &buf, sizeof buf);
    void (*callback)(void *, const void *, uint16_t *) = flush;
    memcpy(driver + 0x20, &callback, sizeof callback);
    native_display *display = native_lvgl.register_display(driver);
    CHECK(display && native_lvgl.default_display() == display, "memory display registration");
    native_obj *top;
    memcpy(&top, (char *)display + 0x38, sizeof top);
    CHECK(top, "top layer");
    native_obj *root = native_lvgl.object_create(top);
    CHECK(root, "root creation");
    native_lvgl.set_position(root, 0, 0);
    native_lvgl.set_size(root, 320, 480);
    native_lvgl.set_style(root, NATIVE_STYLE_RADIUS, 0, 0);
    native_lvgl.set_style(root, NATIVE_STYLE_BORDER_WIDTH, 0, 0);
    for (unsigned prop = NATIVE_STYLE_PAD_TOP; prop <= NATIVE_STYLE_PAD_RIGHT; prop++)
        native_lvgl.set_style(root, prop, 0, 0);
    native_lvgl.set_style(root, NATIVE_STYLE_BG_COLOR, 0x07e0, 0);
    native_lvgl.set_style(root, NATIVE_STYLE_BG_OPACITY, 255, 0);

    expected_target = native_lvgl.button_create(root);
    CHECK(expected_target, "button creation");
    native_lvgl.set_position(expected_target, 16, 50);
    native_lvgl.set_size(expected_target, 200, 44);
    native_obj *label = native_lvgl.label_create(expected_target);
    CHECK(label, "label creation");
    char label_input[] = "L_5G";
    native_lvgl.label_set_text(label, label_input);
    memset(label_input, 'x', sizeof label_input - 1);
    CHECK(!strcmp(native_lvgl.label_get_text(label), "L_5G"), "label owns its text copy");
    CHECK(native_lvgl.add_event(expected_target, clicked, NATIVE_EVENT_CLICKED, &marker), "event registration");
    int event_result = native_lvgl.send_event(expected_target, NATIVE_EVENT_CLICKED, NULL);
    CHECK(event_result == NATIVE_RESULT_OK && clicks == 1 && callback_valid, "click target, code and user data");

    for (unsigned i = 0; i < 50; i++) {
        native_lvgl.timer_handler();
        usleep(2000);
    }
    int16_t coordinates[4];
    memcpy(coordinates, (char *)expected_target + 0x28, sizeof coordinates);
    CHECK(coordinates[0] == 16 && coordinates[1] == 50 &&
          coordinates[2] == 215 && coordinates[3] == 93, "button position and dimensions");
    CHECK(flushes > 0 && pixels[320 * 480 - 1] == 0x07e0, "native renderer and RGB565 background");
    native_lvgl.add_flag(root, NATIVE_HIDDEN);
    uint32_t flags;
    memcpy(&flags, (char *)root + 0x30, sizeof flags);
    CHECK(flags & NATIVE_HIDDEN, "hide panel");
    native_lvgl.clear_flag(root, NATIVE_HIDDEN);
    memcpy(&flags, (char *)root + 0x30, sizeof flags);
    CHECK(!(flags & NATIVE_HIDDEN), "show panel");
    puts("Native LVGL: initialization, layout, label ownership, click events, visibility and memory rendering passed");
    return 0;
}

int __libc_start_main(int (*original)(int, char **, char **), int argc, char **argv,
                     void (*init)(void), void (*fini)(void), void (*ldso)(void)) {
    (void)original;
    int (*real)(int (*)(int, char **, char **), int, char **, void (*)(void), void (*)(void), void (*)(void));
    *(void **)&real = dlsym(RTLD_NEXT, "__libc_start_main");
    if (!real) _Exit(125);
    return real(probe_main, argc, argv, init, fini, ldso);
}
