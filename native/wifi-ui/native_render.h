#ifndef OPENU60_NATIVE_RENDER_H
#define OPENU60_NATIVE_RENDER_H
#include "lvgl_abi.h"
#include <string.h>

static inline void native_label_text(native_obj *object, const char *text) {
    /* The pinned LVGL frees/reallocates text and invalidates its region even
     * for identical strings. Polling must not turn an idle view into animation. */
    const char *current = native_lvgl.label_get_text(object);
    if (!current || strcmp(current, text)) native_lvgl.label_set_text(object, text);
}
static inline void native_visible(native_obj *object, int visible) {
    uint32_t flags; memcpy(&flags, (char *)object + 0x30, sizeof flags);
    if (visible && (flags & NATIVE_HIDDEN)) native_lvgl.clear_flag(object, NATIVE_HIDDEN);
    else if (!visible && !(flags & NATIVE_HIDDEN)) native_lvgl.add_flag(object, NATIVE_HIDDEN);
}
#endif
