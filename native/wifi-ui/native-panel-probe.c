#define _GNU_SOURCE
#include "native_panel.c"
#include "native_layout.h"
#include "native_home.h"
#include "menu-fixture.h"
#include "font-fixture.h"
#include "lock-fixture.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <unistd.h>

#define CHECK(condition, message) do { if (!(condition)) { \
    fprintf(stderr, "Native panel failure: %s\n", message); return 1; \
} } while (0)
static unsigned flushes;
static uint16_t rendered[320 * 480];
static int pointer_down;
static int16_t pointer_point[2] = {159, 267};
static void read_pointer(void *driver, void *data) {
    (void)driver;
    memcpy(data, pointer_point, sizeof pointer_point);
    memcpy((char *)data + 0x10, &pointer_down, sizeof pointer_down);
}
static void pointer_frame(int pressed) {
    pointer_down = pressed;
    for (unsigned i = 0; i < 30; i++) {native_lvgl.timer_handler(); usleep(2000);}
}
static void tap(int x, int y) {
    pointer_point[0]=(int16_t)(319-x);pointer_point[1]=(int16_t)(479-y);
    pointer_frame(0);pointer_frame(1);pointer_frame(0);
}
static void flush(void *driver, const void *area, uint16_t *pixels) {
    int16_t bounds[4]; memcpy(bounds, area, sizeof bounds);
    if (bounds[0] < 0 || bounds[1] < 0 || bounds[2] >= 320 || bounds[3] >= 480 ||
        bounds[2] < bounds[0] || bounds[3] < bounds[1]) _Exit(2);
    unsigned width = (unsigned)(bounds[2] - bounds[0] + 1);
    /* LVGL flushes dirty rectangles, so its reusable draw buffer alone is not
     * a screenshot. Composite each rectangle as the physical driver does. */
    for (int y = bounds[1]; y <= bounds[3]; y++) {
        memcpy(rendered + y * 320 + bounds[0], pixels, width * sizeof *pixels);
        pixels += width;
    }
    flushes++; native_lvgl.flush_ready(driver);
}
static void click(struct control *control) {
    if (!control) _Exit(2);
    uint32_t flags; memcpy(&flags, (char *)control->object + 0x30, sizeof flags);
    if (!(flags & 2)) {fputs("Native panel failure: touch target is not clickable\n", stderr); _Exit(1);}
    if (native_lvgl.send_event(control->object, NATIVE_EVENT_CLICKED, NULL) != NATIVE_RESULT_OK) _Exit(2);
}
static struct control *find(enum action action, int value) {
    for (unsigned i = 0; i < control_count; i++) if (controls[i].action == action && controls[i].value == value) return &controls[i];
    return NULL;
}
static int probe_main(int argc, char **argv, char **environment) {
    (void)environment;
    CHECK(ui_json_init() == 0, "JSON ABI");
    native_lvgl.init();
    CHECK(!font_fixture(), "initialize the native Chinese font fixture");
    int (*glyph)(const void *,void *,uint32_t,uint32_t);
    uintptr_t font=NATIVE_MENU_FONT_20;memcpy(&glyph,(void *)font,sizeof glyph);
    unsigned char glyph_data[64]={0};
    CHECK(glyph((void *)font,glyph_data,0x4e2d,0), "native font renders Chinese glyphs");
    font=NATIVE_FONT_14;memcpy(&glyph,(void *)font,sizeof glyph);
    CHECK(glyph((void *)font,glyph_data,0xf079,0), "firmware symbol font renders the mode-switch icon");
    static _Alignas(16) unsigned char driver[0x98], buffer[0x28];
    static uint16_t pixels[320 * 480];
    native_lvgl.driver_init(driver);
    native_lvgl.buffer_init(buffer, pixels, NULL, 320 * 480);
    void *buf = buffer; memcpy(driver + 0x10, &buf, sizeof buf);
    void (*callback)(void *, const void *, uint16_t *) = flush;
    memcpy(driver + 0x20, &callback, sizeof callback);
    native_display *display = native_lvgl.register_display(driver);
    CHECK(display, "memory display");
    native_obj *top; memcpy(&top, (char *)display + 0x38, sizeof top);
    CHECK(native_panel_create(top) == 0, "native control creation");
    CHECK(control_count == 55, "bounded control pool");
    native_obj *screen = native_active_screen(display), *layers[4];
    for (unsigned i = 0; i < 4; i++) {
        layers[i] = native_lvgl.object_create(screen);CHECK(layers[i], "stock layer fixture");
        native_lvgl.set_position(layers[i], 0, 0);native_lvgl.set_size(layers[i], 320, 480);
        surface(layers[i], UI_BLACK);
        if (i)native_lvgl.add_flag(layers[i], NATIVE_HIDDEN);
    }
    native_obj *factory_list = menu_fixture(layers[0]);CHECK(factory_list, "factory Wi-Fi menu fixture");
    int32_t *current_route;memcpy(&current_route, (void *)0xe6fca8, sizeof current_route);
    CHECK(current_route, "factory menu route controller");*current_route = 6;
    for (unsigned i = 0; i < 30; i++) {native_lvgl.timer_handler();usleep(2000);}
    CHECK(!native_panel_refresh(1), "attach to the native Wi-Fi menu");
    native_obj *entry_parent;memcpy(&entry_parent, (char *)launcher->object + 8, sizeof entry_parent);
    CHECK(entry_parent == factory_list, "repeater is an item in the native Wi-Fi list");
    CHECK(native_child(factory_list, 2) == launcher->object && !native_child(factory_list, 10),
          "one repeater row follows the two factory hotspot switches");
    uintptr_t entry_class;memcpy(&entry_class, launcher->object, sizeof entry_class);
    CHECK(entry_class == 0xe60248, "the entry uses the factory menu button class");
    CHECK(!strcmp(native_lvgl.label_get_text(launcher->label), "Wi-Fi 中继"),
          "the repeater entry matches the native menu language");
    CHECK(native_lvgl.get_style(launcher->label,0,NATIVE_STYLE_TEXT_FONT) ==
          native_lvgl.get_style(native_child(native_child(factory_list,0),0),0,NATIVE_STYLE_TEXT_FONT),
          "the entry shares the native menu font instance");
    CHECK(native_lvgl.get_style(launcher->object,0,NATIVE_STYLE_RADIUS) == 16 &&
          native_lvgl.get_style(launcher->object,0,NATIVE_STYLE_BG_COLOR) == rgb(0x181818),
          "the entry matches native menu rounding and background");
    uintptr_t arrow_class;memcpy(&arrow_class,launcher->detail,sizeof arrow_class);
    CHECK(arrow_class == 0xe60368, "the entry uses the native menu chevron image");
    const void *arrow_source;memcpy(&arrow_source,(char *)launcher->detail+0x38,sizeof arrow_source);
    CHECK(arrow_source == NATIVE_MENU_CHEVRON, "the entry shares the native arrow artwork");
    native_obj *cached_submenu = native_lvgl.object_create(layers[0]);CHECK(cached_submenu, "cached factory submenu");
    native_lvgl.add_flag(cached_submenu, NATIVE_HIDDEN);native_lvgl.move_to_index(cached_submenu, 1);
    CHECK(!native_panel_refresh(1), "return from a cached native submenu without fixed child indices");
    const char *fixture = "{\"ok\":true,\"data\":{\"config\":{\"mode\":\"repeater\",\"band\":\"5g\",\"ssid\":\"Home\",\"security\":\"wpa2\",\"has_password\":true,\"mac_mode\":\"factory\",\"clone_mac\":\"\"},\"phase\":\"connected\",\"busy\":false,\"connectivity\":\"online\",\"ipv4\":\"192.0.2.2\",\"networks\":[{\"ssid\":\"Home\",\"security\":\"wpa2\",\"supported\":true,\"frequency\":5200,\"signal\":-35},{\"ssid\":\"Home\",\"security\":\"wpa2\",\"supported\":true,\"frequency\":5200,\"signal\":-60},{\"ssid\":\"Guest\",\"security\":\"open\",\"supported\":true,\"frequency\":5200,\"signal\":-45}]}}";
    ui_status(j_parse(fixture)); native_panel_refresh(1);
    /* Match the physical display's 180-degree input rotation and dispatch a
     * real pointer press/release through the pinned LVGL hit-testing path. */
    uint32_t display_flags; memcpy(&display_flags, driver + 0x18, sizeof display_flags);
    display_flags = (display_flags & ~0x30u) | 0x20;
    memcpy(driver + 0x18, &display_flags, sizeof display_flags);
    static _Alignas(8) unsigned char pointer_driver[0x38];
    void (*init_pointer)(void *) = (void *)0x475170;
    void *(*register_pointer)(void *) = (void *)0x4751b4;
    init_pointer(pointer_driver);
    uint32_t pointer_type = 1; memcpy(pointer_driver, &pointer_type, sizeof pointer_type);
    void (*pointer_callback)(void *, void *) = read_pointer;
    memcpy(pointer_driver + 8, &pointer_callback, sizeof pointer_callback);
    memcpy(pointer_driver + 0x20, &display, sizeof display);
    CHECK(register_pointer(pointer_driver), "memory pointer registration");
    pointer_frame(0); pointer_frame(1); pointer_frame(0);
    CHECK(ui.page == 1 && ui.network_count == 2, "launcher and SSID grouping");
    CHECK(strstr(ui.command, "scan"), "native scan submits a real controller request");
    ui_clear(ui.command, sizeof ui.command); ui.in_flight = 0; ui_status(j_parse(fixture)); native_panel_refresh(1);
    click(find(BACK, 0)); CHECK(ui.page == 0 && native_current_form() == 6 &&
        !native_is_hidden(launcher->object), "Back returns to the native Wi-Fi menu");
    for (unsigned i = 0; i < 50; i++) {native_lvgl.timer_handler();usleep(2000);}
    CHECK(!native_panel_refresh(1), "refresh the extended native menu");
    for (unsigned i = 0; i < 50; i++) {native_lvgl.timer_handler();usleep(2000);}
    int16_t menu_bounds[4], last_bounds[4];
    int16_t entry_arrow[4],native_arrow[4];
    memcpy(entry_arrow,(char *)launcher->detail+0x28,sizeof entry_arrow);
    native_obj *reference_row=native_child(factory_list,4);
    memcpy(native_arrow,(char *)native_child(reference_row,2)+0x28,sizeof native_arrow);
    CHECK(entry_arrow[0]==native_arrow[0]&&entry_arrow[2]==native_arrow[2]&&
          entry_arrow[1]-entry_arrow[3]==native_arrow[1]-native_arrow[3],
          "native menu chevrons share horizontal bounds and height");
    memcpy(menu_bounds, (char *)factory_list + 0x28, sizeof menu_bounds);
    memcpy(last_bounds, (char *)native_child(factory_list, 8) + 0x28, sizeof last_bounds);
    CHECK(menu_bounds[3] >= last_bounds[3] + 8, "the scrollable list includes its last original option");
    if (argc >= 6) {
        void (*invalidate)(native_obj *) = (void *)0x42cfe8;
        invalidate(screen);
        for (unsigned i = 0; i < 50; i++) {native_lvgl.timer_handler();usleep(2000);}
        FILE *output = fopen(argv[5], "wb");CHECK(output, "native menu preview output");
        CHECK(fwrite(rendered, sizeof rendered, 1, output) == 1 && !fclose(output), "complete native menu preview");
    }
    click(launcher); CHECK(ui.page == 1 && !ui_busy() && ui.network_count == 2, "reopening uses the fresh scan cache");
    click(scan); CHECK(ui_busy() && strstr(ui.command, "scan"), "manual Scan bypasses the fresh cache");
    ui_clear(ui.command, sizeof ui.command); ui.in_flight = 0; ui_status(j_parse(fixture)); native_panel_refresh(1);
    CHECK(!strcmp(native_lvgl.label_get_text(status_label), "已联网"), "localized online state");
    CHECK(!strcmp(native_lvgl.label_get_text(scan->label), "扫描") &&
          !strcmp(native_lvgl.label_get_text(other->label), "其他网络"), "localized network actions");
    CHECK(!strcmp(native_lvgl.label_get_text(network[0]->label), "Home"), "network row");
    tap(246,100);
    CHECK(ui.page==5&&!*ui.command&&!native_is_hidden(hotspot_confirmation),
          "SIM action opens confirmation without changing the network");
    tap(80,202);CHECK(ui.page==5&&!*ui.command,"confirmation blocks touches on the network list");
    if (argc >= 8) {
        FILE *output=fopen(argv[7],"wb");CHECK(output,"mode confirmation preview output");
        CHECK(fwrite(rendered,sizeof rendered,1,output)==1&&!fclose(output),"complete mode confirmation preview");
    }
    tap(94,312);CHECK(ui.page==1&&!*ui.command&&native_is_hidden(hotspot_confirmation),
          "Cancel leaves the upstream connection unchanged");
    click(hotspot);ui.busy=1;native_panel_refresh(1);
    CHECK(!hotspot_confirm->enabled,"a pending operation disables mode confirmation");
    ui_confirm_hotspot();CHECK(!*ui.command,"busy confirmation cannot submit an apply request");
    ui.busy=0;native_panel_refresh(1);tap(226,312);
    CHECK(ui.page==1&&ui.busy&&strstr(ui.command,"hotspot"),"only explicit confirmation submits SIM mode");
    ui_clear(ui.command,sizeof ui.command);ui.in_flight=ui.busy=0;
    ui_status(j_parse(fixture));native_panel_refresh(1);
    click(hotspot);native_panel_refresh(0);
    CHECK(ui.page==0&&native_is_hidden(hotspot_confirmation),"locking cancels pending mode confirmation");
    native_panel_refresh(1);click(launcher);
    click(network[0]); CHECK(ui.page == 2 && !strcmp(ui.ssid, "Home"), "native join selection");
    click(find(SYMBOLS, 0)); click(find(SHIFT, 0));
    const char *question = strchr(ui_keys(), '?'); CHECK(question, "question mark keyboard page");
    click(keyboard[question - ui_keys()]);
    CHECK(!strcmp(ui.password, "?"), "native keyboard input");
    CHECK(!strcmp(native_lvgl.label_get_text(password->label), "*"), "password display is masked");
    click(find(BACK, 0)); CHECK(ui.page == 1 && !*ui.password, "back clears password");
    click(find(APP_CONNECT, 0)); CHECK(ui.page == 4, "device connection entry");
    strcpy(ui.connection_code, "U60-00000000-0000-4000-8000-000000000001");
    strcpy(ui.connection_server, "https://synthetic.invalid/openu60");
    native_panel_refresh(1);
    CHECK(!native_is_hidden(connection_page) && native_is_hidden(list), "connection string page replaces the network list");
    CHECK(connection_qr_ready && !native_is_hidden(connection_qr_background), "connection QR renders with public metadata");
    struct json_object *qr = j_parse(connection_qr_payload);
    CHECK(qr && !strcmp(json_text(qr, "type"), "openu60-connect") && j_int(j_get(qr, "version")) == 1 &&
        !strcmp(json_text(qr, "device"), ui.connection_code) && !strcmp(json_text(qr, "server"), ui.connection_server),
        "QR preserves the device and server together");
    j_put(qr);
    for (unsigned i = 0; i < 50; i++) {native_lvgl.timer_handler(); usleep(2000);}
    if (argc >= 3) {
        FILE *output = fopen(argv[2], "wb"); CHECK(output, "QR preview output");
        CHECK(fwrite(rendered, sizeof rendered, 1, output) == 1 && !fclose(output), "complete rendered QR preview");
    }
    strcpy(ui.connection_error, "Device offline"); native_panel_refresh(1);
    CHECK(!connection_qr_ready && native_is_hidden(connection_qr_background), "unavailable metadata hides the old QR");
    *ui.connection_error = 0;
    memset(ui.connection_server, 'a', sizeof ui.connection_server - 1);
    memcpy(ui.connection_server, "https://synthetic.invalid/", 26);
    ui.connection_server[sizeof ui.connection_server - 1] = 0;
    native_panel_refresh(1);
    CHECK(connection_qr_ready, "long server address fits the QR canvas");
    qr = j_parse(connection_qr_payload);
    CHECK(qr && !strcmp(json_text(qr, "server"), ui.connection_server), "long server addresses remain complete in the QR");
    j_put(qr);
    click(find(BACK, 0)); CHECK(ui.page == 1, "connection page returns to networks");
    click(other); CHECK(ui.page == 3 && !strcmp(ui.security, "auto"), "Other uses Auto security");
    ui_connect();native_panel_refresh(1);
    CHECK(!strcmp(native_lvgl.label_get_text(form_hint), "请输入网络名称。"), "validation errors use the native menu language");
    strcpy(ui.error,"Synthetic backend failure");native_panel_refresh(1);
    CHECK(!strcmp(native_lvgl.label_get_text(form_hint), "操作失败：Synthetic backend failure"),
          "unexpected failures preserve their diagnostic detail");
    *ui.error=0;native_panel_refresh(1);
    for (unsigned i = 0; i < 50; i++) {native_lvgl.timer_handler(); usleep(2000);}
    if (argc >= 4) {
        FILE *output = fopen(argv[3], "wb"); CHECK(output, "keyboard preview output");
        CHECK(fwrite(rendered, sizeof rendered, 1, output) == 1 && !fclose(output), "complete rendered keyboard preview");
    }
    uint32_t connect_flags; memcpy(&connect_flags, (char *)connect_button->object + 0x30, sizeof connect_flags);
    CHECK(!(connect_flags & 2), "empty SSID disables Connect");
    for (const char *p = "Hidden"; *p; p++) ui_key(*p);
    ui.field = 1;
    int printable[127] = {0}; printable[' '] = 1;
    for (ui.symbols = 0; ui.symbols <= 1; ui.symbols++) for (ui.shift = 0; ui.shift <= 1; ui.shift++) {
        CHECK(strlen(ui_keys()) <= 30, "all keyboard keys are visible");
        for (const char *p = ui_keys(); *p; p++) printable[(unsigned char)*p] = 1;
    }
    for (int c = 32; c <= 126; c++) CHECK(printable[c], "full printable ASCII password keyboard");
    ui.symbols = ui.shift = 0;
    for (int i = 0; i < 65; i++) ui_key('a');
    CHECK(strlen(ui.password) == 64, "64-digit WPA2 key boundary");
    native_panel_refresh(1); CHECK(strlen(native_lvgl.label_get_text(password->label)) == 64, "64-character mask");
    click(connect_button);
    CHECK(ui.page == 1 && !*ui.password && ui.busy, "connect applies and clears the password");
    struct json_object *request = j_parse(ui.command), *body = j_get(request, "body");
    CHECK(!strcmp(j_string(j_get(request, "action")), "apply") && strlen(j_string(j_get(body, "password"))) == 64, "complete private input reaches the owning command");
    j_put(request); ui_clear(ui.command, sizeof ui.command); ui.in_flight = 0; ui.busy = 0;
    ui_status(j_parse(fixture)); native_panel_refresh(1);
    for (unsigned i = 0; i < 50; i++) {native_lvgl.timer_handler(); usleep(2000);}
    CHECK(flushes && rendered[320 * 480 - 1] == rgb(UI_BLACK), "native renderer draws the panel");
    unsigned idle_flushes = flushes;
    for (unsigned i = 0; i < 5; i++) native_panel_refresh(1);
    for (unsigned i = 0; i < 50; i++) {native_lvgl.timer_handler(); usleep(2000);}
    CHECK(flushes == idle_flushes, "unchanged network list must not keep redrawing");
    strcpy(ui.error, "Synthetic scan failure"); native_panel_refresh(1);
    for (unsigned i = 0; i < 50; i++) {native_lvgl.timer_handler(); usleep(2000);}
    CHECK(flushes > idle_flushes, "changed network status redraws promptly");
    *ui.error = 0; native_panel_refresh(1);
    for (unsigned i = 0; i < 50; i++) {native_lvgl.timer_handler(); usleep(2000);}
    if (argc >= 2) {
        FILE *output = fopen(argv[1], "wb"); CHECK(output, "preview output");
        CHECK(fwrite(rendered, sizeof rendered, 1, output) == 1 && !fclose(output), "complete preview");
    }
    if (argc >= 5) {
        /* A synthetic factory Home supplies only its inspected geometry. The
         * real extension and renderer produce the preview, without hardware,
         * network, saved configuration or passwords. */
        native_lvgl.object_clean(layers[0]);surface(layers[0], UI_BLACK);
        for (unsigned i = 1; i < 4; i++) native_lvgl.add_flag(layers[i], NATIVE_HIDDEN);
        for (unsigned i = 0; i < 3; i++) {
            native_obj *child = native_lvgl.object_create(layers[0]); CHECK(child, "Home preview body");
            surface(child, UI_BLACK);
            native_lvgl.set_position(child, 0, i == 2 ? 24 : 0);
            native_lvgl.set_size(child, 320, i == 2 ? 456 : 24);
        }
        native_obj *content = native_lvgl.object_create(native_child(layers[0], 2)); CHECK(content, "Home preview content");
        surface(content, UI_BLACK); native_lvgl.set_position(content, 0, 0); native_lvgl.set_size(content, 320, 432);
        for (unsigned i = 0; i < 20; i++) {
            native_obj *child = native_lvgl.object_create(content); CHECK(child, "Home preview geometry");
            native_lvgl.add_flag(child, NATIVE_HIDDEN);
        }
        int32_t *route; memcpy(&route, (void *)0xe6fca8, sizeof route);
        CHECK(route, "Home preview route controller"); *route = 0;
        ui.page = 0; ui.rates_valid = 1; ui.rx_rate = 10471250; ui.tx_rate = 525000;
        ui_hotspot_status("state=ENABLED\nssid[0]=Travel Wi-Fi\n");
        native_panel_refresh(1);
        for (unsigned i = 0; i < 50; i++) {native_lvgl.timer_handler(); usleep(2000);}
        CHECK(!native_home_refresh(display, 1), "Home preview binding");
        for (unsigned i = 0; i < 50; i++) {native_lvgl.timer_handler(); usleep(2000);}
        FILE *output = fopen(argv[4], "wb"); CHECK(output, "Home preview output");
        CHECK(fwrite(rendered, sizeof rendered, 1, output) == 1 && !fclose(output), "complete rendered Home preview");
        CHECK(!native_home_refresh(display, 0), "hide the Home preview");
        for (unsigned i = 1; i < 4; i++) native_lvgl.clear_flag(layers[i], NATIVE_HIDDEN);
    }
    if (argc >= 7) {
        native_obj *lock_body=lock_fixture(layers[2]);CHECK(lock_body,"lock preview geometry");
        native_lvgl.add_flag(layers[3],NATIVE_HIDDEN);
        for(unsigned i=0;i<30;i++){native_lvgl.timer_handler();usleep(2000);}
        CHECK(!native_home_refresh(display,0),"lock preview binding");
        for(unsigned i=0;i<30;i++){native_lvgl.timer_handler();usleep(2000);}
        static uint16_t before_lock_notice[320*480];memcpy(before_lock_notice,rendered,sizeof rendered);
        native_label_text(native_child(lock_body,1),"原生网络提示已更新");
        for(unsigned i=0;i<30;i++){native_lvgl.timer_handler();usleep(2000);}
        CHECK(!memcmp(before_lock_notice+64*320,rendered+64*320,85*320*sizeof *rendered)&&
              !memcmp(before_lock_notice+330*320,rendered+330*320,48*320*sizeof *rendered),
              "repeater text stays visible when the covered native lock notice redraws");
        FILE *output=fopen(argv[6],"wb");CHECK(output,"lock preview output");
        CHECK(fwrite(rendered,sizeof rendered,1,output)==1&&!fclose(output),"complete rendered lock preview");
        native_lvgl.clear_flag(layers[3],NATIVE_HIDDEN);
    }
    /* The real renderer resolves coordinates before the main-loop hook runs. */
    for (unsigned i = 0; i < 50; i++) {native_lvgl.timer_handler(); usleep(2000);}
    native_obj *bound_screen = NULL, *bound_lock = NULL;
    CHECK(!native_stock_unlocked(display, &bound_screen, &bound_lock), "visible stock lock blocks the extension");
    native_lvgl.add_flag(layers[2], NATIVE_HIDDEN); native_lvgl.add_flag(layers[3], NATIVE_HIDDEN);
    CHECK(native_stock_unlocked(display, &bound_screen, &bound_lock), "stock unlock reveals the extension");
    native_lvgl.clear_flag(layers[3], NATIVE_HIDDEN);
    CHECK(!native_stock_unlocked(display, &bound_screen, &bound_lock), "stock modal blocks the extension");
    strcpy(ui.password, "synthetic-input"); ui.page = 2;
    native_panel_refresh(0); click(launcher);
    CHECK(ui.page == 0 && !*ui.password, "lock hides controls and clears private input");
    native_obj *replacement = native_lvgl.object_create(NULL);
    CHECK(replacement, "replacement factory screen fixture");
    for (unsigned i = 0; i < 4; i++) {
        native_obj *layer = native_lvgl.object_create(replacement);
        CHECK(layer, "replacement factory layer fixture");
        native_lvgl.set_position(layer, 0, 0); native_lvgl.set_size(layer, 320, 480);
        if (i >= 2) native_lvgl.add_flag(layer, NATIVE_HIDDEN);
    }
    /* This isolated memory display has no vendor controller; select its
     * synthetic active screen directly before the real renderer lays it out. */
    memcpy((char *)display + 0x20, &replacement, sizeof replacement);
    for (unsigned i = 0; i < 50; i++) {native_lvgl.timer_handler(); usleep(2000);}
    CHECK(native_stock_unlocked(display, &bound_screen, &bound_lock) && bound_screen == replacement,
          "a recognized replacement factory screen can unlock the extension");
    CHECK(menu_fixture(native_child(replacement, 0)), "replacement Wi-Fi menu fixture");
    *current_route = 6;
    for (unsigned i = 0; i < 30; i++) {native_lvgl.timer_handler();usleep(2000);}
    for (unsigned cleanup = 0; cleanup < 2; cleanup++) {
        ui.page = 3; strcpy(ui.password, "synthetic-input");
        if (cleanup) native_lvgl.object_clean(top);
        else native_lvgl.object_delete(form);
        CHECK(!native_panel_refresh(1), "rebuild custom controls after a factory deletion");
        CHECK(ui.page == 0 && !*ui.password, "factory cleanup clears the editing session");
        CHECK(control_count == 55 && !native_is_hidden(launcher->object) && !native_child(top, 3),
              "recreate one panel without retaining surviving duplicate roots");
        click(launcher);
        CHECK(ui.page == 1, "rebuilt network launcher remains interactive");
    }
    native_obj *replacement_home = native_child(replacement, 0);
    native_lvgl.object_clean(replacement_home);
    CHECK(native_panel_refresh(1) == 1, "wait for an incomplete factory Wi-Fi page");
    CHECK(menu_fixture(replacement_home), "rebuilt factory Wi-Fi menu");
    for (unsigned i = 0; i < 30; i++) {native_lvgl.timer_handler();usleep(2000);}
    CHECK(!native_panel_refresh(1), "rebind after the factory deletes its Wi-Fi page");
    factory_list = native_child(native_child(replacement_home, 3), 0);
    CHECK(native_child(factory_list, 2) == launcher->object && !native_child(factory_list, 10),
          "factory Wi-Fi reconstruction retains exactly one entry");
    puts("Native Wi-Fi: real LVGL click routing, scan/grouping, join, masked input, keyboard coverage, apply, lock and rendering passed");
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
