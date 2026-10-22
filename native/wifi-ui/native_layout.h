#ifndef OPENU60_NATIVE_LAYOUT_H
#define OPENU60_NATIVE_LAYOUT_H
#include "lvgl_abi.h"
#include <string.h>

/* Verified in the pinned ELF and by metadata-only inspection of its running UI.
 * The active screen owns home, menu, lock and modal layers in that order. */
static inline native_obj *native_child(native_obj *object, unsigned index) {
    void *attributes; memcpy(&attributes, (char *)object + 0x10, sizeof attributes);
    if (!attributes) return NULL;
    uint32_t count; memcpy(&count, (char *)attributes + 8, sizeof count);
    if (count > 16 || index >= count) return NULL;
    native_obj **children; memcpy(&children, attributes, sizeof children);
    if (!children) return NULL;
    native_obj *child; memcpy(&child, children + index, sizeof child); return child;
}
static inline native_obj *native_active_screen(native_display *display) {
    native_obj *screen; memcpy(&screen, (char *)display + 0x20, sizeof screen); return screen;
}
static inline int native_full_screen(native_obj *object) {
    if (!object) return 0;
    int16_t coordinates[4]; memcpy(coordinates, (char *)object + 0x28, sizeof coordinates);
    return coordinates[0] == 0 && coordinates[1] == 0 && coordinates[2] == 319 && coordinates[3] == 479;
}
static inline int native_is_hidden(native_obj *object) {
    uint32_t flags; memcpy(&flags, (char *)object + 0x30, sizeof flags); return !!(flags & NATIVE_HIDDEN);
}
static inline int native_current_form(void) {
    /* The pinned SwitchForm routine stores the active public route ID at the
     * start of this controller. Home's carousel keeps route zero on both pages. */
    void *controller; memcpy(&controller, (void *)0xe6fca8, sizeof controller);
    if (!controller) return -1;
    int32_t id; memcpy(&id, controller, sizeof id);
    return id >= 0 && id <= 0xff ? id : -1;
}
static inline int native_stock_unlocked(native_display *display, native_obj **bound_screen, native_obj **bound_lock) {
    native_obj *screen = native_active_screen(display);
    if (!screen) return 0;
    native_obj *lock = native_child(screen, 2);
    if (screen != *bound_screen || lock != *bound_lock) {
        if (!native_full_screen(screen)) return 0;
        for (unsigned i = 0; i < 4; i++) if (!native_full_screen(native_child(screen, i))) return 0;
        if (native_child(screen, 4)) return 0;
        /* Only the current screen's validated layers are followed. A factory
         * screen replacement must not leave the extension permanently locked. */
        *bound_screen = screen; *bound_lock = lock;
    }
    native_obj *modal = native_child(screen, 3);
    return modal && native_is_hidden(*bound_lock) && native_is_hidden(modal);
}
#endif
