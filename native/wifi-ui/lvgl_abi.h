#ifndef OPENU60_LVGL_ABI_H
#define OPENU60_LVGL_ABI_H
#include <stdint.h>
#include <string.h>

/* Private, statically linked LVGL ABI in the exact factory executable whose
 * SHA-256 is 7a158227890ddd5dc247ab1d198cef3cf69a13d2667892a980effc2a9f509ca0.
 * These addresses cannot be used with a different binary or a PIE relocation.
 * Isolated behavior tests validate the calls; physical integration is separate. */
typedef struct native_obj native_obj;
typedef struct native_event native_event;
typedef struct native_display native_display;
typedef void (*native_event_cb)(native_event *);
struct native_lvgl_api {
    void (*init)(void);
    int (*is_initialized)(void);
    void (*driver_init)(void *);
    void (*buffer_init)(void *, void *, void *, uint32_t);
    native_display *(*register_display)(void *);
    native_display *(*default_display)(void);
    void (*flush_ready)(void *);
    uint32_t (*timer_handler)(void);
    native_obj *(*object_create)(native_obj *);
    void (*object_delete)(native_obj *);
    void (*object_clean)(native_obj *);
    void (*set_parent)(native_obj *, native_obj *);
    void (*move_to_index)(native_obj *, int32_t);
    native_obj *(*button_create)(native_obj *);
    native_obj *(*menu_button_create)(native_obj *);
    native_obj *(*image_create)(native_obj *);
    void (*image_set_source)(native_obj *, const void *);
    native_obj *(*label_create)(native_obj *);
    native_obj *(*qrcode_create)(native_obj *, int16_t, uint16_t, uint16_t);
    int (*qrcode_update)(native_obj *, const void *, uint32_t);
    void (*label_set_text)(native_obj *, const char *);
    void (*label_set_long_mode)(native_obj *, uint8_t);
    const char *(*label_get_text)(native_obj *);
    void (*set_position)(native_obj *, int16_t, int16_t);
    void (*set_size)(native_obj *, int16_t, int16_t);
    void (*set_style)(native_obj *, uint32_t, uint64_t, uint32_t);
    uint64_t (*get_style)(native_obj *, uint32_t, uint32_t);
    void (*add_flag)(native_obj *, uint32_t);
    void (*clear_flag)(native_obj *, uint32_t);
    void *(*add_event)(native_obj *, native_event_cb, uint32_t, void *);
    int (*send_event)(native_obj *, uint32_t, void *);
    native_obj *(*event_target)(native_event *);
    uint32_t (*event_code)(native_event *);
    void *(*event_user_data)(native_event *);
};

static const struct native_lvgl_api native_lvgl = {
    .init = (void *)0x429bfc,
    .is_initialized = (void *)0x429bf0,
    .driver_init = (void *)0x4744dc,
    .buffer_init = (void *)0x474550,
    .register_display = (void *)0x47459c,
    .default_display = (void *)0x474904,
    .flush_ready = (void *)0x475010,
    .timer_handler = (void *)0x47cf34,
    .object_create = (void *)0x429d24,
    .object_delete = (void *)0x433ec0,
    .object_clean = (void *)0x433fe0,
    .set_parent = (void *)0x434058,
    .move_to_index = (void *)0x434238,
    .button_create = (void *)0x4633d0,
    .menu_button_create = (void *)0x483058,
    .image_create = (void *)0x4895f4,
    .image_set_source = (void *)0x489638,
    .label_create = (void *)0x48ac70,
    .qrcode_create = (void *)0x456714,
    .qrcode_update = (void *)0x45676c,
    .label_set_text = (void *)0x48bfe8,
    .label_set_long_mode = (void *)0x48c3e0,
    .label_get_text = (void *)0x48acd4,
    .set_position = (void *)0x42bfc4,
    .set_size = (void *)0x42c158,
    .set_style = (void *)0x432458,
    .get_style = (void *)0x4317e0,
    .add_flag = (void *)0x429d68,
    .clear_flag = (void *)0x429e9c,
    .add_event = (void *)0x424b48,
    .send_event = (void *)0x424a10,
    .event_target = (void *)0x424ab4,
    .event_code = (void *)0x424abc,
    .event_user_data = (void *)0x424ad0,
};

enum {
    NATIVE_RESULT_OK = 1,
    NATIVE_HIDDEN = 1,
    NATIVE_EVENT_CLICKED = 7,
    NATIVE_EVENT_DELETE = 33,
    NATIVE_STYLE_RADIUS = 11,
    NATIVE_STYLE_PAD_TOP = 16,
    NATIVE_STYLE_PAD_BOTTOM = 17,
    NATIVE_STYLE_PAD_LEFT = 18,
    NATIVE_STYLE_PAD_RIGHT = 19,
    NATIVE_STYLE_BG_COLOR = 32,
    NATIVE_STYLE_BG_OPACITY = 33,
    NATIVE_STYLE_BORDER_WIDTH = 50,
    NATIVE_STYLE_BORDER_COLOR = 48,
    NATIVE_STYLE_SHADOW_WIDTH = 64,
    NATIVE_STYLE_TEXT_COLOR = 85,
    NATIVE_STYLE_TEXT_OPACITY = 86,
    NATIVE_STYLE_TEXT_FONT = 87,
    NATIVE_STYLE_TEXT_ALIGN = 91,
};
/* Built-in Montserrat descriptors in the pinned firmware, including its symbol
 * glyphs. Reuse the renderer's fonts rather than loading another font engine. */
#define NATIVE_FONT_14 ((uintptr_t)0xe5fd98)
#define NATIVE_FONT_20 ((uintptr_t)0xe5fe28)
#define NATIVE_FONT_28 ((uintptr_t)0xe5feb8)
#define NATIVE_FONT_40 ((uintptr_t)0xe60008)
/* Use the factory font manager's active family, including its Chinese glyphs.
 * Descriptors are cached by the factory; heap addresses must never be pinned. */
static inline uintptr_t native_font(unsigned size, unsigned type) {
    void *(*manager)(void) = (void *)0x557ee4;
    const unsigned char *(*info)(void *, unsigned, unsigned) = (void *)0x55851c;
    const unsigned char *value = info(manager(),size,type);
    uintptr_t font = 0;if(value)memcpy(&font,value+0x18,sizeof font);
    return font;
}
#define NATIVE_MENU_FONT_16 (native_font(16,0))
#define NATIVE_MENU_FONT_20 (native_font(20,0))
/* The lock screen requests the factory's numeric family (type 6) at 64 px.
 * Its wallpaper and direction icons are immutable image descriptors in this
 * executable, not pointers into a live lock page. */
#define NATIVE_LOCK_RATE_FONT (native_font(64,6))
#define NATIVE_LOCK_BACKGROUND ((const void *)0xe61488)
#define NATIVE_LOCK_UPLOAD ((const void *)0xe614a8)
#define NATIVE_LOCK_DOWNLOAD ((const void *)0xe61498)
#define NATIVE_MENU_CHEVRON ((const void *)0xe611d8)
#define NATIVE_UI_SLEEP_RETURN ((uintptr_t)0x40fc34)
#endif
