#ifndef OPENU60_MENU_FIXTURE_H
#define OPENU60_MENU_FIXTURE_H
#include "native_layout.h"
#include "native_theme.h"
#include "native_render.h"

/* Public geometry of the pinned Wi-Fi settings form. It contains synthetic
 * labels and controls only; the factory backend and configuration are unused. */
static native_obj *menu_fixture(native_obj *form) {
    native_lvgl.object_clean(form);
    native_surface(form, UI_BLACK, 0);
    for (unsigned i = 0; i < 4; i++) {
        native_obj *child = native_lvgl.object_create(form);
        if (!child) return NULL;
        native_surface(child, UI_BLACK, 0);
        native_lvgl.set_position(child, 0, i == 2 ? 0 : i == 3 ? 66 : 24);
        native_lvgl.set_size(child, 320, i == 2 ? 24 : i == 3 ? 414 : i == 1 ? 42 : 456);
        if (!i) native_lvgl.add_flag(child, NATIVE_HIDDEN);
        if (i == 3)native_lvgl.add_flag(child, 0x10);
    }
    native_obj *title = native_lvgl.label_create(native_child(form, 1));
    if (!title) return NULL;
    native_lvgl.set_position(title, 42, 10);native_lvgl.set_size(title, 236, 32);
    native_type(title, NATIVE_MENU_FONT_20, 0xe7e7e7, 1);native_label_text(title, "Wi-Fi");
    native_obj *body = native_child(form, 3), *list = native_lvgl.label_create(body);
    if (!list) return NULL;
    native_label_text(list, "");
    native_surface(list, UI_BLACK, 0);
    native_lvgl.set_position(list, 10, 8);native_lvgl.set_size(list, 300, 404);
    for (unsigned p = NATIVE_STYLE_PAD_TOP; p <= NATIVE_STYLE_PAD_RIGHT; p++)native_lvgl.set_style(list, p, 8, 0);
    void (*column)(native_obj *, unsigned) = (void *)0x446a34;
    column(list, 1);
    static const char *names[] = {"Wi-Fi", "多频合一", "同步 Wi-Fi", "Wi-Fi 频段",
        "最大连接数", "主 Wi-Fi", "访客 Wi-Fi", "WPS", "NFC"};
    for (unsigned i = 0; i < 9; i++) {
        native_obj *(*make_button)(native_obj *) = (void *)0x483058;
        native_obj *row = make_button(list);
        if (!row) return NULL;
        native_surface(row, 0x181818, 16);native_lvgl.set_size(row, 284, i == 5 || i == 6 ? 64 : 52);
        for (unsigned j = 0; j < 3; j++) {
            native_obj *child;
            if (j == 2 && i < 2) {
                native_obj *(*make_switch)(native_obj *) = (void *)0x490024;
                child = make_switch(row);
            } else if (j == 2) {
                child = native_lvgl.image_create(row);
                if (child)native_lvgl.image_set_source(child, NATIVE_MENU_CHEVRON);
            } else child = native_lvgl.label_create(row);
            if (!child) return NULL;
            if (j == 1)native_label_text(child, "");
            if (j == 2) {
                native_lvgl.set_position(child, i < 2 ? 223 : 252, (i == 5 || i == 6 ? 64 : 52) / 2 - 12);
                native_lvgl.set_size(child, i < 2 ? 44 : 24, 24);
            }
            if (!j) {
                native_lvgl.set_position(child, 8, 14);native_lvgl.set_size(child, 240, 24);
                native_type(child, NATIVE_MENU_FONT_20, 0xe7e7e7, 0);native_label_text(child, names[i]);
            }
        }
        if (i == 2 || i == 8) native_lvgl.add_flag(row, NATIVE_HIDDEN);
    }
    return list;
}
#endif
