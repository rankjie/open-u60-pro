#include "native_home.h"
#include "native_layout.h"
#include "native_render.h"
#include "native_theme.h"
#include "ui.h"
#include <stdio.h>
#include <string.h>

struct status_card {
    native_obj *owner, *panel, *network, *state, *hotspot, *download, *upload, *down_unit, *up_unit;
};
static struct status_card home_card, lock_card;
static int shown;
static void deleted(native_event *event) {
    struct status_card *card=native_lvgl.event_user_data(event);
    if (!card || native_lvgl.event_target(event)!=card->panel)return;
    if (card==&home_card)shown=0;
    memset(card,0,sizeof *card);
}
static native_obj *text(native_obj *parent,int x,int y,int width,int height,uintptr_t font,int align) {
    native_obj *label=native_lvgl.label_create(parent);if (!label)return NULL;
    native_lvgl.set_position(label,(int16_t)x,(int16_t)y);native_lvgl.set_size(label,(int16_t)width,(int16_t)height);
    native_type(label,font,0xe7e7e7,0);
    native_lvgl.set_style(label,NATIVE_STYLE_TEXT_ALIGN,(uint64_t)align,0);
    native_lvgl.set_style(label,NATIVE_STYLE_TEXT_OPACITY,255,0);
    return label;
}
static native_obj *image(native_obj *parent,int x,int y,const void *source) {
    native_obj *object=native_lvgl.image_create(parent);if (!object)return NULL;
    native_lvgl.image_set_source(object,source);native_lvgl.set_position(object,(int16_t)x,(int16_t)y);return object;
}
static int bind_card(native_obj *parent,struct status_card *card) {
    if (card->panel && parent!=card->owner)native_lvgl.object_delete(card->panel);
    if (card->panel)return 0;
    void *attributes;uint32_t count;int16_t bounds[4];
    memcpy(&attributes,(char *)parent+0x10,sizeof attributes);if (!attributes)return 1;
    memcpy(&count,(char *)attributes+8,sizeof count);memcpy(bounds,(char *)parent+0x28,sizeof bounds);
    int home=card==&home_card;
    if (count!=(home?20u:14u)||bounds[0]!=0||bounds[1]!=24||bounds[2]!=319||bounds[3]!=(home?455:479))return 1;
    uintptr_t title_font=native_font(24,0),status_font=native_font(18,0),rate_font=NATIVE_LOCK_RATE_FONT;
    if (!title_font||!status_font||!rate_font||!NATIVE_MENU_FONT_16||!NATIVE_MENU_FONT_20)return -1;
    card->panel=native_lvgl.object_create(parent);if (!card->panel)return -1;
    card->owner=parent;
    if (!native_lvgl.add_event(card->panel,deleted,NATIVE_EVENT_DELETE,card))return -1;
    native_lvgl.set_position(card->panel,0,0);native_lvgl.set_size(card->panel,320,home?432:354);
    native_surface(card->panel,UI_BLACK,0);
    /* An opaque shared card keeps lock and Home consistent during partial
     * redraws. Its lock height leaves native notifications and unlock intact. */
    if (home)native_lvgl.add_flag(card->panel,2|(1u<<15));
    else native_lvgl.clear_flag(card->panel,2);
    if (!image(card->panel,0,0,NATIVE_LOCK_BACKGROUND))return -1;
    native_obj *heading=text(card->panel,0,40,320,30,title_font,2);
    card->network=text(card->panel,18,70,284,30,title_font,2);
    card->state=text(card->panel,0,100,320,25,status_font,2);
    card->upload=text(card->panel,18,130,160,70,rate_font,3);
    if (!image(card->panel,184,142,NATIVE_LOCK_UPLOAD))return -1;
    card->up_unit=text(card->panel,187,168,88,30,NATIVE_MENU_FONT_20,1);
    card->download=text(card->panel,18,205,160,70,rate_font,3);
    if (!image(card->panel,184,217,NATIVE_LOCK_DOWNLOAD))return -1;
    card->down_unit=text(card->panel,187,243,88,30,NATIVE_MENU_FONT_20,1);
    card->hotspot=text(card->panel,18,306,284,48,NATIVE_MENU_FONT_16,2);
    if (!heading||!card->network||!card->state||!card->upload||!card->up_unit||!card->download||!card->down_unit||!card->hotspot)return -1;
    native_label_text(heading,"Wi-Fi 中继");native_lvgl.label_set_long_mode(card->network,4);
    native_lvgl.set_style(card->state,NATIVE_STYLE_TEXT_COLOR,native_rgb(0x848484),0);
    native_lvgl.add_flag(card->panel,NATIVE_HIDDEN);return 0;
}
static void update_card(struct status_card *card,const char *ssid,const char *status,const char *ap,
                        const char *down,const char *up,const char *down_suffix,const char *up_suffix) {
    native_label_text(card->network,ssid);native_label_text(card->state,status);native_label_text(card->hotspot,ap);
    native_label_text(card->download,down);native_label_text(card->upload,up);
    native_label_text(card->down_unit,down_suffix);native_label_text(card->up_unit,up_suffix);
    native_visible(card->panel,1);
}
static void rate(char *output, size_t capacity, char *unit, size_t unit_capacity, int valid, uint64_t bytes) {
    if (!valid) {snprintf(output, capacity, "--"); *unit = 0; return;}
    static const char *units[] = {"Kb/s", "Mb/s", "Gb/s", "Tb/s", "Pb/s", "Eb/s"};
    double value = (double)bytes * 8 / 1000;
    unsigned scale = 0;
    /* Promote before one-decimal rounding would produce a fifth digit that
     * cannot fit the lock screen's numeric column. */
    while (value >= 999.95 && scale + 1 < sizeof units / sizeof *units) {value /= 1000; scale++;}
    snprintf(output, capacity, "%.1f", value);
    snprintf(unit, unit_capacity, "%s", units[scale]);
}
int native_home_refresh(native_display *display, int unlocked) {
    char ssid[128], status[80], ap[160], down[32], up[32], down_suffix[8], up_suffix[8];
    pthread_mutex_lock(&ui.mutex);
    struct json_object *data = ui.status ? j_get(ui.status, "data") : NULL;
    struct json_object *config = data ? j_get(data, "config") : NULL;
    struct json_object *mode_value = config ? j_get(config, "mode") : NULL;
    const char *mode = mode_value ? j_string(mode_value) : NULL;
    struct json_object *ssid_value = config ? j_get(config, "ssid") : NULL;
    const char *name = ssid_value ? j_string(ssid_value) : NULL;
    int repeater = mode && !strcmp(mode, "repeater");
    int enabled = unlocked && !ui.page && repeater;
    if (repeater) {
        snprintf(ssid, sizeof ssid, "%s", name && *name ? name : "网络名称不可用");
        snprintf(status, sizeof status, "%s", ui.online
                 ? ui.rates_valid ? "已联网" : "已联网 · 速率暂不可用"
                 : *ui.error ? "无法获取状态" : ui_busy() ? "正在连接…"
                 : ui.connected ? "需认证或网络受限" : "未连接");
        rate(down, sizeof down, down_suffix, sizeof down_suffix, ui.rates_valid, ui.rx_rate);
        rate(up, sizeof up, up_suffix, sizeof up_suffix, ui.rates_valid, ui.tx_rate);
        if (ui.hotspot_state == UI_HOTSPOT_ENABLED)snprintf(ap, sizeof ap, "热点：%s", ui.hotspot_ssid);
        else snprintf(ap, sizeof ap, "%s", ui.hotspot_state == UI_HOTSPOT_DISABLED ? "热点未开启" : "热点状态不可用");
    }
    pthread_mutex_unlock(&ui.mutex);
    native_obj *active=native_active_screen(display);
    native_obj *lock=active?native_child(active,2):NULL,*modal=active?native_child(active,3):NULL;
    int lock_enabled=repeater&&!unlocked&&lock&&!native_is_hidden(lock)&&modal&&native_is_hidden(modal);
    native_obj *lock_body=lock_enabled?native_child(lock,1):NULL;
    if (lock_body&&!native_is_hidden(lock_body)) {
        int result=bind_card(lock_body,&lock_card);if (result)return result;
        update_card(&lock_card,ssid,status,ap,down,up,down_suffix,up_suffix);
    } else if (lock_card.panel)native_visible(lock_card.panel,0);
    if (enabled) {
        int route = native_current_form();
        if (route < 0) {shown = 0; return 1;}
        enabled = route == 0;
    }
    native_obj *screen = enabled ? native_active_screen(display) : NULL;
    native_obj *home = screen ? native_child(screen, 0) : NULL;
    shown = 0;
    if (!enabled || (home && native_is_hidden(home))) {
        if (home_card.panel) native_visible(home_card.panel, 0);
        return 0;
    }
    /* The factory creates and lays out Home asynchronously during startup.
     * The caller bounds this pending state; an unrecognized layout never gets
     * dereferenced as a different view or accepted as successful integration. */
    native_obj *body = NULL;
    /* Returning from Wi-Fi retains hidden forms ahead of Home. Its body keeps
     * this geometry even though its index changes from two to three. */
    for (unsigned i=0;home && i<16;i++) {
        native_obj *candidate=native_child(home,i);if (!candidate)break;
        if (native_is_hidden(candidate))continue;
        int16_t bounds[4];memcpy(bounds,(char *)candidate+0x28,sizeof bounds);
        if (bounds[0]==0 && bounds[1]==24 && bounds[2]==319 && bounds[3]==479) {body=candidate;break;}
    }
    native_obj *parent = body ? native_child(body, 0) : NULL;
    if (!parent) return 1;
    int result=bind_card(parent,&home_card);if (result)return result;
    update_card(&home_card,ssid,status,ap,down,up,down_suffix,up_suffix);
    shown = 1;
    return 0;
}
int native_home_visible(void) {return shown;}
