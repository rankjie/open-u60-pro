#ifndef OPENU60_NATIVE_THEME_H
#define OPENU60_NATIVE_THEME_H
#include "lvgl_abi.h"

/* The stock screen uses black, white and a blue accent. Keep the extension on
 * that same canvas; gray is reserved for separators, keys and secondary text. */
enum { UI_BLACK = 0x000000, UI_WHITE = 0xffffff, UI_BLUE = 0x009dff,
       UI_SECONDARY = 0x999999, UI_LINE = 0x262626, UI_KEY = 0x191919 };
static inline uint16_t native_rgb(unsigned value) {
    return (uint16_t)((((value >> 19) & 31) << 11) | (((value >> 10) & 63) << 5) | ((value >> 3) & 31));
}
static inline void native_type(native_obj *object, uintptr_t font, unsigned color, int centered) {
    native_lvgl.set_style(object, NATIVE_STYLE_TEXT_FONT, font, 0);
    native_lvgl.set_style(object, NATIVE_STYLE_TEXT_COLOR, native_rgb(color), 0);
    native_lvgl.set_style(object, NATIVE_STYLE_TEXT_ALIGN, centered ? 2 : 1, 0);
}
static inline void native_surface(native_obj *object, unsigned color, int radius) {
    native_lvgl.set_style(object, NATIVE_STYLE_BG_COLOR, native_rgb(color), 0);
    native_lvgl.set_style(object, NATIVE_STYLE_BG_OPACITY, 255, 0);
    native_lvgl.set_style(object, NATIVE_STYLE_BORDER_WIDTH, 0, 0);
    native_lvgl.set_style(object, NATIVE_STYLE_SHADOW_WIDTH, 0, 0);
    native_lvgl.set_style(object, NATIVE_STYLE_RADIUS, (uint64_t)radius, 0);
    for (unsigned p = NATIVE_STYLE_PAD_TOP; p <= NATIVE_STYLE_PAD_RIGHT; p++)
        native_lvgl.set_style(object, p, 0, 0);
    native_lvgl.clear_flag(object, 0x10);
}
#endif
