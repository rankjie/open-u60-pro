#ifndef OPENU60_LOCK_FIXTURE_H
#define OPENU60_LOCK_FIXTURE_H
#include "native_layout.h"
#include "native_theme.h"
#include "native_render.h"

/* Only public lock geometry and synthetic text. Factory modem, notification
 * state, PIN state and input handlers are not initialized by renderer tests. */
static native_obj *lock_fixture(native_obj *lock) {
    native_lvgl.object_clean(lock);native_surface(lock, UI_BLACK, 0);
    native_obj *bar = native_lvgl.object_create(lock), *body = native_lvgl.object_create(lock);
    if (!bar || !body)return NULL;
    native_lvgl.set_position(bar, 0, 0);native_lvgl.set_size(bar, 320, 24);
    native_lvgl.add_flag(bar, NATIVE_HIDDEN);
    native_surface(body, UI_BLACK, 0);
    native_lvgl.set_position(body, 0, 24);native_lvgl.set_size(body, 320, 456);
    for (unsigned i=0;i<14;i++) {
        native_obj *object;
        int x=0,y=0,width=320,height=24;
        if (i==0 || i==4 || i==7 || i==11) {
            object=native_lvgl.image_create(body);if (!object)return NULL;
            const void *source=i==0?NATIVE_LOCK_BACKGROUND:i==4?NATIVE_LOCK_UPLOAD:
                i==7?NATIVE_LOCK_DOWNLOAD:(const void *)0xe61748;
            native_lvgl.image_set_source(object,source);
            if (i==4 || i==7) {x=184;y=i==4?142:217;width=height=24;}
            else if (i==11) {x=149;y=394;width=22;height=26;}
            else height=456;
        } else if (i==13) {
            object=native_lvgl.object_create(body);if (!object)return NULL;
            native_lvgl.add_flag(object,NATIVE_HIDDEN);
        } else {
            object=native_lvgl.label_create(body);if (!object)return NULL;
            uintptr_t font=NATIVE_MENU_FONT_16;const char *value="";
            if (i==1) {y=40;height=60;font=native_font(24,0);value="无SIM卡\n请插入SIM卡";}
            else if (i==2) {y=100;height=25;font=native_font(18,0);}
            else if (i==3 || i==6) {x=18;y=i==3?130:205;width=160;height=70;font=NATIVE_LOCK_RATE_FONT;value=i==3?"4.2":"83.8";}
            else if (i==5 || i==8) {x=187;y=i==5?168:243;width=88;height=30;font=NATIVE_MENU_FONT_20;value="Mb/s";}
            else if (i==9) {y=366;height=20;}
            else if (i==10) {y=426;height=40;value="长按屏幕解锁";}
            else if (i==12)native_lvgl.add_flag(object,NATIVE_HIDDEN);
            native_type(object,font,0xe7e7e7,1);
            native_lvgl.set_style(object,NATIVE_STYLE_TEXT_OPACITY,255,0);
            if (i==3 || i==6)native_lvgl.set_style(object,NATIVE_STYLE_TEXT_ALIGN,3,0);
            if (i==5 || i==8)native_lvgl.set_style(object,NATIVE_STYLE_TEXT_ALIGN,1,0);
            native_label_text(object,value);
        }
        native_lvgl.set_position(object,(int16_t)x,(int16_t)y);
        native_lvgl.set_size(object,(int16_t)width,(int16_t)height);
    }
    return body;
}
#endif
