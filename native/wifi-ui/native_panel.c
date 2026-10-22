#include "native_panel.h"
#include "native_render.h"
#include "native_theme.h"
#include "native_layout.h"
#include "ui.h"
#include <stdio.h>
#include <string.h>

/* Only the factory LVGL thread may call this module. The status worker owns no
 * native objects, and the screen/input drivers remain entirely with the factory. */
enum { MENU_TEXT=0xe7e7e7, MENU_SECONDARY=0x949a9c, MENU_SURFACE=0x181818 };
enum action {
    OPEN, BACK, APP_CONNECT, HOTSPOT, CANCEL_HOTSPOT, CONFIRM_HOTSPOT, BAND_TWO, BAND_FIVE, SCAN, NETWORK,
    PREVIOUS, NEXT, OTHER, SSID, PASSWORD, CONNECT, KEY, SYMBOLS, SHIFT, SPACE, DELETE
};
struct control { native_obj *object, *label, *detail; enum action action; int value, enabled, highlighted; unsigned ink; };
static struct control controls[56];
static unsigned control_count;
static native_obj *list, *form, *status_label, *upstream_label, *list_hint, *form_title, *form_hint;
static native_obj *connection_page, *connection_code, *connection_server, *connection_error;
static native_obj *connection_qr, *connection_qr_background;
static char connection_qr_payload[4096];
static int connection_qr_ready;
static struct control *launcher, *hotspot, *bands[2], *scan, *network[4], *previous, *next, *other;
static struct control *ssid, *password, *connect_button, *keyboard[30];
static native_obj *hotspot_confirmation;
static struct control *hotspot_confirm;
static native_obj *roots[4];
static native_obj *launcher_owner;
static int can_interact, needs_rebuild;

static void root_deleted(native_event *event) {
    native_obj **root = native_lvgl.event_user_data(event);
    if (!root || *root != native_lvgl.event_target(event)) return;
    *root = NULL; can_interact = 0; needs_rebuild = 1;
}

static uint16_t rgb(unsigned value) {
    return native_rgb(value);
}
static void visible(native_obj *object, int show) {
    native_visible(object, show);
}
static void surface(native_obj *object, unsigned color) {
    native_surface(object, color, 0);
}
static native_obj *label(native_obj *parent, int x, int y, int width, int height, const char *text) {
    native_obj *object = native_lvgl.label_create(parent);
    if (!object) return NULL;
    native_lvgl.set_position(object, (int16_t)x, (int16_t)y);
    native_lvgl.set_size(object, (int16_t)width, (int16_t)height);
    native_type(object, NATIVE_MENU_FONT_20, MENU_TEXT, 0);
    native_label_text(object, text);
    return object;
}
static const char *json_text(struct json_object *object, const char *key) {
    struct json_object *value = object ? j_get(object, key) : NULL;
    const char *text = value ? j_string(value) : NULL;
    return text ? text : "";
}
static void error_label(native_obj *object, const char *message) {
    static const struct {const char *source,*localized;} messages[] = {
        {"Invalid local Wi-Fi status.","本机 Wi-Fi 状态异常。"},
        {"Wi-Fi status is out of date.","Wi-Fi 状态已过期，请稍候重试。"},
        {"Wait for the current Wi-Fi operation.","请等待当前 Wi-Fi 操作完成。"},
        {"Wi-Fi request is too large.","Wi-Fi 请求内容过长。"},
        {"Enter the network name.","请输入网络名称。"},
        {"Enter the Wi-Fi password.","请输入 Wi-Fi 密码。"},
        {"Local Wi-Fi service is unavailable.","本机 Wi-Fi 服务暂不可用。"},
        {"Remote access is unavailable","远程连接暂不可用。"},
        {"Device offline","设备已离线。"},
        {"A Wi-Fi operation is already running","请等待当前 Wi-Fi 操作完成。"},
        {"Wait for the current Wi-Fi operation to finish","请等待当前 Wi-Fi 操作完成。"},
        {"Wi-Fi worker is unavailable","Wi-Fi 服务暂不可用。"},
        {"Connect the Wi-Fi uplink first","请先连接上游 Wi-Fi。"},
        {"Invalid Wi-Fi mode settings","Wi-Fi 模式设置有误。"},
        {"Select a scan band","请选择扫描频段。"},
        {"SSID must contain 1–32 bytes and no control characters","网络名称须为 1–32 字节，且不能含控制字符。"},
        {"The upstream Wi-Fi did not provide an IPv4 address","上游 Wi-Fi 未分配 IP 地址。"},
        {"Upstream Wi-Fi did not provide a default gateway","上游 Wi-Fi 未提供默认网关。"},
    };
    if (!*message) {native_label_text(object, "");return;}
    for (unsigned i=0;i<sizeof messages/sizeof messages[0];i++)
        if (!strcmp(message,messages[i].source)) {native_label_text(object,messages[i].localized);return;}
    /* Preserve unexpected backend details rather than turning a failure into a
     * generic status. Technical diagnostics may retain their original wording. */
    char detail[768];snprintf(detail,sizeof detail,"操作失败：%s",message);native_label_text(object,detail);
}
static void refresh_locked(void);
static void clicked(native_event *event) {
    struct control *control = native_lvgl.event_user_data(event);
    if (!control || !can_interact) return;
    pthread_mutex_lock(&ui.mutex);
    if (ui.page == 5 && control->action != CANCEL_HOTSPOT && control->action != CONFIRM_HOTSPOT) {
        pthread_mutex_unlock(&ui.mutex); return;
    }
    int editing = ui.page == 2 || ui.page == 3;
    switch (control->action) {
    case OPEN:
        if (launcher_owner && native_current_form() == 6) ui_open();
        break;
    case BACK: ui_back(); break;
    case APP_CONNECT: ui.page = 4; break;
    case HOTSPOT: ui_hotspot(); break;
    case CANCEL_HOTSPOT: if (ui.page == 5) ui_back(); break;
    case CONFIRM_HOTSPOT: ui_confirm_hotspot(); break;
    case BAND_TWO: ui_band(2); break;
    case BAND_FIVE: ui_band(5); break;
    case SCAN: ui_band(ui.band); break;
    case NETWORK: ui_select(ui.offset + control->value); break;
    case PREVIOUS: if (ui.offset >= 4) ui.offset -= 4; break;
    case NEXT: if (ui.offset + 4 < ui.network_count) ui.offset += 4; break;
    case OTHER: ui_other(); break;
    case SSID: if (ui.page == 3) ui.field = 0; break;
    case PASSWORD: ui.field = 1; break;
    case CONNECT: ui_connect(); break;
    case KEY: {
        const char *keys = ui_keys();
        if (editing && (size_t)control->value < strlen(keys)) ui_key(keys[control->value]);
        break;
    }
    case SYMBOLS: if (editing) ui.symbols = !ui.symbols; break;
    case SHIFT: if (editing) ui.shift = !ui.shift; break;
    case SPACE: if (editing) ui_key(' '); break;
    case DELETE: if (editing) ui_delete(); break;
    }
    refresh_locked();
    pthread_mutex_unlock(&ui.mutex);
}
static struct control *button(native_obj *parent, int x, int y, int width, int height,
                              const char *text, enum action action, int value) {
    if (control_count >= sizeof controls / sizeof controls[0]) return NULL;
    struct control *control = &controls[control_count++];
    control->object = native_lvgl.menu_button_create(parent);
    if (!control->object) return NULL;
    native_lvgl.set_position(control->object, (int16_t)x, (int16_t)y);
    native_lvgl.set_size(control->object, (int16_t)width, (int16_t)height);
    int key = action >= KEY;
    int field = action == SSID || action == PASSWORD;
    int primary = action == CONNECT || action == CONFIRM_HOTSPOT;
    int header_action = action == BACK || action == APP_CONNECT;
    surface(control->object, primary ? UI_BLUE : header_action ? UI_BLACK : MENU_SURFACE);
    native_lvgl.add_flag(control->object, 2);
    native_lvgl.set_style(control->object, NATIVE_STYLE_RADIUS, key ? 6 : header_action ? 0 : 16, 0);
    /* The pressed selector belongs to the factory's LV_STATE_PRESSED. */
    native_lvgl.set_style(control->object, NATIVE_STYLE_BG_COLOR, rgb(primary ? 0x007dce : UI_LINE), 0x20);
    control->label = label(control->object, field ? 10 : 0, field ? 6 : (height - 24) / 2,
                           width - (field ? 20 : 0), field ? height - 12 : 24, text);
    if (!control->label) return NULL;
    control->ink = MENU_TEXT;
    native_type(control->label, action == HOTSPOT || action == PREVIOUS || action == NEXT ||
                action == PASSWORD || action == SYMBOLS || action == SHIFT || action == SPACE || action == DELETE
                ? NATIVE_MENU_FONT_16 : NATIVE_MENU_FONT_20,
                control->ink, !field && action != NETWORK && action != OTHER && action != OPEN);
    if (action == HOTSPOT) {
        control->detail = label(control->object, 8, (height - 20) / 2, 20, 20, "\xef\x81\xb9");
        if (!control->detail) return NULL;
        native_type(control->detail, NATIVE_FONT_14, MENU_TEXT, 1);
        native_lvgl.set_position(control->label, 31, (height - 24) / 2);
        native_lvgl.set_size(control->label, width - 35, 24);
        native_type(control->label, NATIVE_MENU_FONT_16, MENU_TEXT, 0);
    } else if (action == NETWORK || action == OTHER || action == OPEN) {
        int detail_width = action == NETWORK ? 64 : 24;
        native_lvgl.set_position(control->label, 8, (height - 24) / 2);
        native_lvgl.set_size(control->label, width - detail_width - 20, 24);
        if (action == OPEN) {
            control->detail = native_lvgl.image_create(control->object);
            if (control->detail) {
                native_lvgl.image_set_source(control->detail, NATIVE_MENU_CHEVRON);
                native_lvgl.set_position(control->detail, width - 32, (height - 24) / 2);
            }
        } else control->detail = label(control->object, width - detail_width - 8, (height - 20) / 2, detail_width, 20, "");
        if (!control->detail) return NULL;
        if (action != OPEN)native_type(control->detail, NATIVE_MENU_FONT_16, MENU_SECONDARY, 1);
    }
    control->action = action; control->value = value;
    control->enabled = 1;
    if (!native_lvgl.add_event(control->object, clicked, NATIVE_EVENT_CLICKED, control)) return NULL;
    return control;
}
static native_obj *page(native_obj *top) {
    native_obj *object = native_lvgl.object_create(top);
    if (!object) return NULL;
    native_lvgl.set_position(object, 0, 24);
    native_lvgl.set_size(object, 320, 456);
    surface(object, UI_BLACK);
    native_lvgl.set_style(object, NATIVE_STYLE_RADIUS, 0, 0);
    native_lvgl.add_flag(object, 2); /* Consume touches in gaps instead of reaching the stock page. */
    native_lvgl.add_flag(object, NATIVE_HIDDEN);
    return object;
}
static int header(native_obj *parent, const char *title, int qr) {
    if (!button(parent, 0, 0, 64, 42, "‹", BACK, 0)) return -1;
    native_obj *heading = label(parent, 64, 8, 192, 32, title);
    if (!heading) return -1;
    native_type(heading, NATIVE_MENU_FONT_20, MENU_TEXT, 1);
    if (qr && !button(parent, 240, 0, 80, 42, "连接", APP_CONNECT, 0)) return -1;
    return 0;
}
int native_panel_create(native_obj *top) {
    if (!top || control_count || !NATIVE_MENU_FONT_16 || !NATIVE_MENU_FONT_20) return -1;
    launcher = button(top, 0, 0, 284, 52, "Wi-Fi 中继", OPEN, 0);
    list = page(top); form = page(top); connection_page = page(top);
    if (!launcher || !list || !form || !connection_page) return -1;
    roots[0] = launcher->object; roots[1] = list; roots[2] = form; roots[3] = connection_page;
    for (unsigned i = 0; i < 4; i++)
        if (!native_lvgl.add_event(roots[i], root_deleted, NATIVE_EVENT_DELETE, &roots[i])) return -1;
    needs_rebuild = 0;
    if (header(connection_page, "连接 App", 0)) return -1;
    native_obj *qr_help = label(connection_page, 16, 62, 288, 40, "使用 OpenU60 扫码连接\n然后在手机输入管理密码");
    if (!qr_help) return -1;
    native_type(qr_help, NATIVE_MENU_FONT_16, MENU_SECONDARY, 1);
    connection_qr_background = native_lvgl.object_create(connection_page);
    if (!connection_qr_background) return -1;
    native_lvgl.set_position(connection_qr_background, 24, 108);
    native_lvgl.set_size(connection_qr_background, 272, 272);
    surface(connection_qr_background, 0xffffff);
    native_lvgl.set_style(connection_qr_background, NATIVE_STYLE_RADIUS, 0, 0);
    /* Four light modules remain outside the integer-scaled QR at its largest scale. */
    connection_qr = native_lvgl.qrcode_create(connection_qr_background, 240, 0, 0xffff);
    if (!connection_qr) return -1;
    native_lvgl.set_position(connection_qr, 16, 16);
    connection_code = label(connection_page, 16, 380, 288, 38, "正在读取…");
    connection_server = label(connection_page, 16, 422, 288, 34, "");
    connection_error = label(connection_page, 32, 180, 256, 168, "");
    if (!connection_code || !connection_server || !connection_error) return -1;
    native_type(connection_code, NATIVE_MENU_FONT_16, MENU_TEXT, 1);
    native_type(connection_server, NATIVE_MENU_FONT_16, MENU_SECONDARY, 1);
    native_type(connection_error, NATIVE_MENU_FONT_20, MENU_TEXT, 1);
    if (header(list, "Wi-Fi 中继", 1) || header(form, "连接 Wi-Fi", 0)) return -1;
    upstream_label = label(list, 18, 52, 168, 28, "");
    status_label = label(list, 18, 80, 168, 22, "正在读取…");
    if (status_label) native_type(status_label, NATIVE_MENU_FONT_16, MENU_SECONDARY, 0);
    hotspot = button(list, 190, 52, 112, 48, "SIM 热点", HOTSPOT, 0);
    bands[0] = button(list, 18, 104, 96, 44, "2.4 GHz", BAND_TWO, 0);
    bands[1] = button(list, 118, 104, 96, 44, "5 GHz", BAND_FIVE, 0);
    scan = button(list, 218, 104, 84, 44, "扫描", SCAN, 0);
    for (int i = 0; i < 4; i++) {
        network[i] = button(list, 18, 152 + i * 52, 284, 52, "", NETWORK, i);
    }
    previous = button(list, 18, 360, 136, 44, "上一页", PREVIOUS, 0);
    next = button(list, 166, 360, 136, 44, "下一页", NEXT, 0);
    list_hint = label(list, 18, 360, 284, 44, "");
    if (list_hint) native_type(list_hint, NATIVE_MENU_FONT_16, MENU_SECONDARY, 0);
    other = button(list, 18, 404, 284, 52, "其他网络", OTHER, 0);
    if (other) native_label_text(other->detail, "+");
    form_title = label(form, 16, 58, 288, 42, "");
    ssid = button(form, 18, 96, 284, 52, "网络名称", SSID, 0);
    password = button(form, 18, 152, 284, 52, "密码", PASSWORD, 0);
    connect_button = button(form, 18, 210, 284, 44, "连接", CONNECT, 0);
    form_hint = label(form, 18, 256, 284, 22, "");
    if (form_hint) native_type(form_hint, NATIVE_MENU_FONT_16, MENU_SECONDARY, 0);
    for (int i = 0; i < 30; i++) keyboard[i] = button(form, i % 10 * 32, 280 + i / 10 * 42, 30, 40, "", KEY, i);
    if (!button(form, 0, 408, 72, 44, "符号", SYMBOLS, 0) ||
        !button(form, 76, 408, 70, 44, "大写", SHIFT, 0) ||
        !button(form, 150, 408, 86, 44, "空格", SPACE, 0) ||
        !button(form, 240, 408, 80, 44, "删除", DELETE, 0)) return -1;
    /* Keep the confirmation inside the list's owned root so factory cleanup
     * and lock transitions invalidate it with the rest of this UI session. */
    hotspot_confirmation = native_lvgl.object_create(list);
    if (!hotspot_confirmation) return -1;
    native_lvgl.set_position(hotspot_confirmation, 0, 0);
    native_lvgl.set_size(hotspot_confirmation, 320, 456);
    surface(hotspot_confirmation, UI_BLACK);
    native_lvgl.set_style(hotspot_confirmation, NATIVE_STYLE_BG_OPACITY, 204, 0);
    native_lvgl.add_flag(hotspot_confirmation, 2);
    native_obj *dialog = native_lvgl.object_create(hotspot_confirmation);
    if (!dialog) return -1;
    native_lvgl.set_position(dialog, 18, 112);
    native_lvgl.set_size(dialog, 284, 224);
    native_surface(dialog, MENU_SURFACE, 16);
    native_obj *heading = label(dialog, 16, 24, 252, 32, "切换到 SIM 热点？");
    native_obj *explanation = label(dialog, 16, 72, 252, 56, "将断开上游 Wi-Fi\n改用 SIM 卡联网");
    if (!heading || !explanation) return -1;
    native_type(heading, NATIVE_MENU_FONT_20, MENU_TEXT, 1);
    native_type(explanation, NATIVE_MENU_FONT_16, MENU_SECONDARY, 1);
    struct control *cancel = button(dialog, 16, 152, 120, 48, "取消", CANCEL_HOTSPOT, 0);
    hotspot_confirm = button(dialog, 148, 152, 120, 48, "切换", CONFIRM_HOTSPOT, 0);
    if (!cancel || !hotspot_confirm) return -1;
    native_surface(cancel->object, UI_LINE, 16);
    if (!status_label || !upstream_label || !hotspot || !bands[0] || !bands[1] || !scan ||
        !previous || !next || !other || !list_hint || !form_title || !ssid || !password || !connect_button || !form_hint) return -1;
    for (unsigned i = 0; i < control_count; i++) if (!controls[i].object || !controls[i].label) return -1;
    return native_panel_refresh(0);
}
static void enable(struct control *control, int enabled) {
    enabled = !!enabled;
    if (control->enabled == enabled) return;
    if (enabled) native_lvgl.add_flag(control->object, 2);
    else native_lvgl.clear_flag(control->object, 2);
    if (control->action == CONNECT || control->action == CONFIRM_HOTSPOT)
        native_lvgl.set_style(control->object, NATIVE_STYLE_BG_COLOR, rgb(enabled ? UI_BLUE : MENU_SURFACE), 0);
    native_lvgl.set_style(control->label, NATIVE_STYLE_TEXT_COLOR, rgb(enabled ? control->ink : MENU_SECONDARY), 0);
    if (control->action == HOTSPOT)
        native_lvgl.set_style(control->detail, NATIVE_STYLE_TEXT_COLOR, rgb(enabled ? control->ink : MENU_SECONDARY), 0);
    control->enabled = enabled;
}
static void highlight(struct control *control, int highlighted) {
    highlighted = !!highlighted;
    if (control->highlighted == highlighted) return;
    if (control->action == SSID || control->action == PASSWORD) {
        native_lvgl.set_style(control->object, NATIVE_STYLE_BORDER_COLOR, rgb(UI_BLUE), 0);
        native_lvgl.set_style(control->object, NATIVE_STYLE_BORDER_WIDTH, highlighted ? 1 : 0, 0);
    } else native_lvgl.set_style(control->object, NATIVE_STYLE_BG_COLOR, rgb(highlighted ? UI_BLUE : MENU_SURFACE), 0);
    control->highlighted = highlighted;
}
static void refresh_connection_qr(void) {
    const char *error = ui.connection_error;
    if (*ui.connection_code && *ui.connection_server && !*error) {
        struct json_object *value = j_new();
        if (!value) { error = "无法生成连接二维码。"; connection_qr_ready = 0; }
        else {
            int invalid = j_add(value, "type", j_text("openu60-connect")) ||
                j_add(value, "version", j_number(1)) || j_add(value, "device", j_text(ui.connection_code)) ||
                j_add(value, "server", j_text(ui.connection_server));
            const char *payload = invalid ? NULL : j_encode(value, JSON_C_TO_STRING_PLAIN);
            if (!payload || strlen(payload) >= sizeof connection_qr_payload) {
                error = "连接信息过长，请手动输入下方连接码。"; connection_qr_ready = 0;
            } else if (!connection_qr_ready || strcmp(payload, connection_qr_payload)) {
                connection_qr_ready = native_lvgl.qrcode_update(connection_qr, payload, (uint32_t)strlen(payload)) == NATIVE_RESULT_OK;
                if (connection_qr_ready) snprintf(connection_qr_payload, sizeof connection_qr_payload, "%s", payload);
                else error = "无法生成二维码，请手动输入下方连接码。";
            }
            j_put(value);
        }
    } else connection_qr_ready = 0;
    visible(connection_qr_background, connection_qr_ready);
    if (*ui.connection_error)error_label(connection_error,error);
    else native_label_text(connection_error,error);
}
static void refresh_locked(void) {
    visible(launcher->object, can_interact && launcher_owner && native_current_form() == 6);
    visible(list, can_interact && (ui.page == 1 || ui.page == 5));
    visible(hotspot_confirmation, can_interact && ui.page == 5);
    visible(form, can_interact && (ui.page == 2 || ui.page == 3));
    visible(connection_page, can_interact && ui.page == 4);
    if (!ui.page || !can_interact) return;
    if (ui.page == 4) {
        native_label_text(connection_code, *ui.connection_code ? ui.connection_code : *ui.connection_error ? "暂不可用" : "正在读取…");
        native_label_text(connection_server, ui.connection_server);
        refresh_connection_qr();
        return;
    }
    int busy = ui_busy();
    if (ui.page == 1 || ui.page == 5) {
        struct json_object *data = ui.status ? j_get(ui.status, "data") : NULL;
        struct json_object *config = data ? j_get(data, "config") : NULL;
        const char *phase = json_text(data, "phase");
        const char *state = busy ? "正在处理…" : ui.online ? "已联网" : ui.connected ? "需认证或网络受限"
            : !config ? "无法获取状态" : !strcmp(json_text(config, "mode"), "hotspot") ? "SIM 热点"
            : !strcmp(phase, "failed") ? "连接失败" : "未连接";
        native_label_text(status_label, state);
        const char *upstream = json_text(config, "ssid");
        native_label_text(upstream_label, *upstream ? upstream : "上游 Wi-Fi");
        visible(hotspot->object, config && strcmp(json_text(config, "mode"), "hotspot"));
        enable(hotspot, !busy); enable(bands[0], !busy); enable(bands[1], !busy); enable(scan, !busy); enable(other, !busy);
        enable(hotspot_confirm, !busy && config && !strcmp(json_text(config, "mode"), "repeater"));
        for (int i = 0; i < 2; i++) highlight(bands[i], ui.band == (i ? 5 : 2));
        native_label_text(scan->label, busy ? "请稍候" : "扫描");
        for (int i = 0; i < 4; i++) {
            int index = ui.offset + i;
            visible(network[i]->object, index < ui.network_count);
            if (index < ui.network_count) {
                native_label_text(network[i]->label, ui.networks[index].ssid);
                native_label_text(network[i]->detail, ui.connected && !strcmp(upstream, ui.networks[index].ssid)
                    ? "已连接" : !strcmp(ui.networks[index].security, "open") ? "开放 >" : "加密 >");
            }
            enable(network[i], !busy);
        }
        const char *error = *ui.error ? ui.error : *json_text(data, "error") ? json_text(data, "error") : json_text(data, "scan_error");
        int paging = ui.network_count > 4 && !busy && !*error;
        visible(previous->object, paging); visible(next->object, paging);
        enable(previous, ui.offset >= 4 && !busy); enable(next, ui.offset + 4 < ui.network_count && !busy);
        if (*error)error_label(list_hint,error);
        else native_label_text(list_hint, busy ? "正在扫描或连接…"
                               : !ui.network_count ? "未发现网络，请切换频段或重新扫描。" : "");
    } else if (ui.page == 2 || ui.page == 3) {
        native_label_text(form_title, ui.page == 3 ? "其他网络" : ui.ssid);
        visible(ssid->object, ui.page == 3);
        native_label_text(ssid->label, *ui.ssid ? ui.ssid : "网络名称");
        char masked[65]; size_t length = strlen(ui.password);
        if (length > 64) length = 64;
        memset(masked, '*', length); masked[length] = 0;
        native_label_text(password->label, length ? masked : ui_saved_password() ? "已保存密码" : "密码");
        ui_clear(masked, sizeof masked);
        error_label(form_hint,ui.error);
        highlight(password, ui.field); highlight(ssid, !ui.field);
        const char *keys = ui_keys();
        for (int i = 0; i < 30; i++) {
            visible(keyboard[i]->object, (size_t)i < strlen(keys));
            if ((size_t)i < strlen(keys)) {char key[2] = {keys[i], 0}; native_label_text(keyboard[i]->label, key);}
        }
        for (unsigned i=0;i<control_count;i++) {
            if (controls[i].action==SYMBOLS)native_label_text(controls[i].label,ui.symbols?"字母":"符号");
            if (controls[i].action==SHIFT)native_label_text(controls[i].label,ui.shift?"小写":"大写");
        }
        enable(connect_button, !busy && *ui.ssid);
    }
}
static void extend_menu(native_obj *parent) {
    int16_t bounds[4];memcpy(bounds, (char *)parent + 0x28, sizeof bounds);
    int bottom = bounds[3];
    for (unsigned i = 0; i < 10; i++) {
        native_obj *row = native_child(parent, i);
        if (!row || native_is_hidden(row)) continue;
        int16_t row_bounds[4];memcpy(row_bounds, (char *)row + 0x28, sizeof row_bounds);
        if (row_bounds[3] + 8 > bottom) bottom = row_bounds[3] + 8;
    }
    /* The factory assigns a fixed list height for its own rows. Include the
     * added row in the parent's scroll extent without moving stock controls. */
    if (bottom > bounds[3])native_lvgl.set_size(parent, bounds[2] - bounds[0] + 1, bottom - bounds[1] + 1);
}
static int bind_menu(void) {
    if (native_current_form() != 6) return 0;
    native_display *display = native_lvgl.default_display();
    native_obj *screen = display ? native_active_screen(display) : NULL;
    native_obj *factory = screen ? native_child(screen, 0) : NULL;
    if (!factory || native_is_hidden(factory)) return 1;
    native_obj *parent = NULL;
    /* Cached native submenus shift the header/status/body child indices. The
     * visible Wi-Fi body retains its inspected geometry and widget signature. */
    for (unsigned i = 0; i < 16; i++) {
        native_obj *body = native_child(factory, i);
        if (!body) break;
        if (native_is_hidden(body)) continue;
        int16_t bounds[4];memcpy(bounds, (char *)body + 0x28, sizeof bounds);
        if (bounds[0] == 0 && bounds[1] == 66 && bounds[2] == 319 && bounds[3] == 479) {
            parent = native_child(body, 0);break;
        }
    }
    if (!parent) return 1;
    if (parent == launcher_owner) {extend_menu(parent);return 0;}
    uintptr_t klass;void *attributes;uint32_t count;
    memcpy(&klass, parent, sizeof klass);memcpy(&attributes, (char *)parent + 0x10, sizeof attributes);
    if (klass != 0xe60398 || !attributes) return 1;
    memcpy(&count, (char *)attributes + 8, sizeof count);
    if (count != 9) return 1;
    for (unsigned i = 0; i < count; i++) {
        native_obj *row = native_child(parent, i);
        if (!row) return 1;
        memcpy(&klass, row, sizeof klass);
        if (klass != 0xe60248) return 1;
        if (i < 2) {
            native_obj *toggle = native_child(row, 2);
            if (!toggle) return 1;
            memcpy(&klass, toggle, sizeof klass);
            if (klass != 0xe60488) return 1;
        }
    }
    /* Join the factory's own scrolling list, after its two hotspot switches.
     * Only our row moves; stock callbacks and their C++ item references stay intact. */
    native_lvgl.set_parent(launcher->object, parent);
    native_lvgl.move_to_index(launcher->object, 2);
    launcher_owner = parent;
    return 0;
}
int native_panel_refresh(int unlocked) {
    if (needs_rebuild) {
        /* The factory owns the top layer's lifetime. Delete only surviving
         * roots we created, then rebind after its cleanup has returned. */
        for (unsigned i = 0; i < 4; i++) if (roots[i]) native_lvgl.object_delete(roots[i]);
        memset(controls, 0, sizeof controls); control_count = 0;
        launcher = NULL; launcher_owner = NULL; list = form = connection_page = NULL;
        connection_qr_ready = 0; *connection_qr_payload = 0;
        pthread_mutex_lock(&ui.mutex);
        ui.page = 0; ui_clear(ui.password, sizeof ui.password);
        pthread_mutex_unlock(&ui.mutex);
        native_display *display = native_lvgl.default_display();
        native_obj *top = NULL;
        if (display) memcpy(&top, (char *)display + 0x38, sizeof top);
        if (!top || native_panel_create(top)) return -1;
    }
    if (!list || !form || !launcher) return -1;
    can_interact = unlocked;
    int menu_result = unlocked ? bind_menu() : 0;
    pthread_mutex_lock(&ui.mutex);
    if (!unlocked && ui.page) {ui.page = 0; ui_clear(ui.password, sizeof ui.password);}
    refresh_locked();
    pthread_mutex_unlock(&ui.mutex);
    return menu_result;
}
