#define _GNU_SOURCE
#include "native_panel.c"
#include "native_hook.c"
#include "menu-fixture.h"
#include "font-fixture.h"
#include "lock-fixture.h"
#include <stdatomic.h>
#include <sys/socket.h>
#include <sys/un.h>

static unsigned iterations;
static native_obj *layers[4];
static int status_socket;
static atomic_uint status_requests;
static atomic_uint scan_started, scan_finished;
static int pending_checked;
static unsigned flush_count;
static void settle(void) {
    for (unsigned i = 0; i < 4; i++) {usleep(40000); native_lvgl.timer_handler();}
}
static void check(int condition, const char *message) {
    if (condition) return;
    fprintf(stderr, "Native main-loop failure: %s\n", message); _Exit(1);
}
static int disconnected_dial(int *value) {if (!value) return -8; *value = 6; return 0;}
static int absent_sim(int *value) {if (!value) return -9; *value = 0; return 0;}
static void check_presentation_contract(void) {
    int (*saved_dial)(int *) = original_dial;
    original_dial = disconnected_dial;
    static const uintptr_t internet_views[] = {0x509ac0, 0x509f98, 0x50e984, 0x50c7c8};
    for (int online = 0; online <= 1; online++) {
        ui.online = online;
        for (unsigned i = 0; i < sizeof internet_views / sizeof *internet_views; i++) {
            int value = -1;
            check(!read_dial_status(internet_views[i], &value) && value == (online ? 2 : 6),
                  "factory update gates follow actual Wi-Fi connectivity");
        }
        int value = -1;
        check(!read_dial_status(0x4c0a38, &value) && value == 6,
              "Home and cellular controls keep the actual modem dial state");
    }
    check(read_dial_status(internet_views[0], NULL) == -8, "preserve SDK errors for invalid output pointers");
    int (*saved_sim)(int *) = original_sim;
    original_sim = absent_sim;
    unsigned char model[0x1d4] = {0}; int disconnected = 6;
    memcpy(model + 0x1d0, &disconnected, sizeof disconnected);
    for (int connected = 0; connected <= 1; connected++) for (int fresh = 0; fresh <= 1; fresh++) {
        ui.connected = connected; ui.rates_valid = fresh;
        int value = -1;
        check(!read_sim_state(0x4b4074, &value) && value == (connected && fresh ? 4 : 0),
              "only the lock formatter accepts fresh upstream traffic without a SIM");
        check(read_lock_connection(0x4b40cc, model) == (connected && fresh ? 2 : 6),
              "the lock cache gate follows association and fresh samples, including captive portals");
        check(!read_dial_status(0x4b4120, &value) && value == (connected && fresh ? 2 : 6),
              "the lock's SDK fallback uses the same traffic gate");
        check(!read_sim_state(0x4c0a38, &value) && value == 0 &&
              !read_dial_status(0x4c0a38, &value) && value == 6 &&
              read_lock_connection(0x4caef0, model) == 6,
              "other modem/SIM consumers and cached model data preserve actual cellular state");
        memcpy(&value, model + 0x1d0, sizeof value);
        check(value == 6, "the cached cellular model is never overwritten");
    }
    check(read_sim_state(0x4b4074, NULL) == -9 && read_dial_status(0x4b4120, NULL) == -8,
          "lock adapters preserve the original SDK pointer error contract");
    int (*getter)(void *); memcpy(&getter, (void *)0xe6b460, sizeof getter);
    check(getter == lock_connection && getter(model) == 6, "the pinned local getter is bound and preserves other callers");
    FILE *maps = fopen("/proc/self/maps", "r"); check(maps != NULL, "read process protection metadata");
    char line[512], permissions[5]; unsigned long long low, high; int readonly = 0;
    while (fgets(line, sizeof line, maps))
        if (sscanf(line, "%llx-%llx %4s", &low, &high, permissions) == 3 && low <= 0xe6b460 && high > 0xe6b460)
            readonly = permissions[0] == 'r' && permissions[1] == '-' && permissions[2] == '-';
    fclose(maps); check(readonly, "the private getter page returns to its read-only protection");
    ui.connected = ui.rates_valid = 0; original_sim = saved_sim;
    ui.online = 0; original_dial = saved_dial;
}
static native_obj *last_child(native_obj *object) {
    void *attributes; native_obj **children; uint32_t count;
    memcpy(&attributes, (char *)object + 0x10, sizeof attributes);
    check(attributes != NULL, "Home fixture child metadata");
    memcpy(&children, attributes, sizeof children); memcpy(&count, (char *)attributes + 8, sizeof count);
    check(count == 21, "one Wi-Fi panel inside the original Home page");
    return children[count - 1];
}
static void check_home(native_display *display) {
    /* Match the inspected Home carousel; children are synthetic and contain no
     * factory configuration, QR images or passwords. */
    int32_t *route; memcpy(&route, (void *)0xe6fca8, sizeof route);
    check(route != NULL, "factory route controller"); *route = 0;
    surface(layers[0], 0);
    for (unsigned i = 0; i < 3; i++) {
        native_obj *child = native_lvgl.object_create(layers[0]); surface(child, 0);
        native_lvgl.set_position(child, 0, i == 2 ? 24 : 0);
        native_lvgl.set_size(child, 320, i == 2 ? 456 : 24);
    }
    native_obj *body = native_child(layers[0], 2);
    native_obj *content = native_lvgl.object_create(body); surface(content, 0);
    native_lvgl.set_position(content, 0, 0); native_lvgl.set_size(content, 320, 432);
    for (unsigned i = 0; i < 19; i++) check(native_lvgl.object_create(content) != NULL, "Home fixture control");
    native_lvgl.timer_handler();
    check(!ui_json_init(), "JSON for the Home fixture");
    ui_status(j_parse("{\"ok\":true,\"data\":{\"config\":{\"mode\":\"repeater\",\"ssid\":\"Fixture\"},\"phase\":\"connected\",\"networks\":[],\"connectivity\":\"online\"}}"));
    ui.rates_valid = 1; ui.rx_rate = 125000; ui.tx_rate = 2000;
    ui_hotspot_status("state=ENABLED\nssid[0]=Travel Wi-Fi\n");
    check(native_home_refresh(display, 1) == 1 && !native_home_visible(), "wait for the factory Home construction to finish");
    check(native_lvgl.object_create(content) != NULL, "final Home fixture control");
    native_lvgl.timer_handler();
    check(!native_home_refresh(display, 1) && native_home_visible(), "Wi-Fi rates replace the Home no-SIM area");
    native_obj *card = last_child(content);
    check(!native_is_hidden(card), "native Home panel is visible");
    check(!strcmp(native_lvgl.label_get_text(native_child(card, 1)), "Wi-Fi 中继") &&
          !strcmp(native_lvgl.label_get_text(native_child(card, 2)), "Fixture"),
          "Home uses the native Chinese heading and actual upstream name");
    check(!strcmp(native_lvgl.label_get_text(native_child(card,10)), "热点：Travel Wi-Fi"),
          "Home identifies its actual broadcast hotspot");
    native_obj *cached=native_lvgl.object_create(layers[0]);check(cached!=NULL,"cached native Wi-Fi form");
    native_lvgl.add_flag(cached,NATIVE_HIDDEN);native_lvgl.move_to_index(cached,1);settle();
    check(!native_home_refresh(display,1)&&native_home_visible(),
          "returning from Wi-Fi locates Home after cached forms shift the body index");
    check(!strcmp(native_lvgl.label_get_text(native_child(card, 4)), "16.0") &&
          !strcmp(native_lvgl.label_get_text(native_child(card, 6)), "Kb/s") &&
          !strcmp(native_lvgl.label_get_text(native_child(card, 7)), "1.0") &&
          !strcmp(native_lvgl.label_get_text(native_child(card, 9)), "Mb/s"),
          "Home uses the lock screen's upload-first numeric and unit layout");
    const void *source;memcpy(&source,(char *)native_child(card,0)+0x38,sizeof source);
    check(source == NATIVE_LOCK_BACKGROUND, "Home renders the original lock wallpaper");
    memcpy(&source,(char *)native_child(card,5)+0x38,sizeof source);
    check(source == NATIVE_LOCK_UPLOAD, "Home renders the lock's yellow upload arrow");
    memcpy(&source,(char *)native_child(card,8)+0x38,sizeof source);
    check(source == NATIVE_LOCK_DOWNLOAD, "Home renders the lock's green download arrow");
    check(native_lvgl.get_style(native_child(card,4),0,NATIVE_STYLE_TEXT_FONT) == NATIVE_LOCK_RATE_FONT &&
          native_lvgl.get_style(native_child(card,1),0,NATIVE_STYLE_TEXT_FONT) == native_font(24,0),
          "Home shares the factory lock's numeric and Chinese font instances");
    static const struct {uint64_t bytes;const char *number,*unit;} rates[] = {
        {0,"0.0","Kb/s"}, {124993,"999.9","Kb/s"},
        {124994,"1.0","Mb/s"}, {125000000,"1.0","Gb/s"},
        {UINT64_MAX,"147.6","Eb/s"},
    };
    for (unsigned i=0;i<sizeof rates/sizeof *rates;i++) {
        ui.rx_rate=rates[i].bytes;
        check(!native_home_refresh(display,1) &&
              !strcmp(native_lvgl.label_get_text(native_child(card,7)),rates[i].number) &&
              !strcmp(native_lvgl.label_get_text(native_child(card,9)),rates[i].unit),
              "zero, rounded unit boundaries and large rates fit the lock's numeric column");
    }
    ui.rx_rate=125000;
    ui.rates_valid = 0;
    check(!native_home_refresh(display, 1) && !strcmp(native_lvgl.label_get_text(native_child(card, 7)), "--") &&
          !*native_lvgl.label_get_text(native_child(card, 9)),
          "missing samples are unavailable rather than invented zero speeds");
    settle(); unsigned before = flush_count;
    for (unsigned i = 0; i < 5; i++) check(!native_home_refresh(display, 1), "unchanged Home status refresh");
    settle();
    check(flush_count == before, "unchanged network status must not redraw the panel");
    /* The factory owns the page lifetime. Rebuilding it must neither reuse a
     * deleted overlay nor restart an otherwise healthy UI thread. */
    native_lvgl.object_clean(content);
    check(!native_home_visible(), "factory page deletion clears the overlay binding");
    check(!native_home_refresh(display, 0) && !native_home_visible(), "lock is safe after the factory clears Home");
    for (unsigned i = 0; i < 20; i++) check(native_lvgl.object_create(content) != NULL, "rebuilt Home control");
    native_lvgl.timer_handler();
    check(!native_home_refresh(display, 1) && native_home_visible(), "rebind the rebuilt factory Home");
    card = last_child(content);
    check(!strcmp(native_lvgl.label_get_text(native_child(card, 1)), "Wi-Fi 中继"), "rebuilt Home retains the network panel");
    native_lvgl.object_delete(content);
    content = native_lvgl.object_create(body); surface(content, 0);
    native_lvgl.set_position(content, 0, 0); native_lvgl.set_size(content, 320, 432);
    for (unsigned i = 0; i < 20; i++) check(native_lvgl.object_create(content) != NULL, "replacement Home control");
    usleep(40000);
    native_lvgl.timer_handler();
    check(!native_home_refresh(display, 1) && native_home_visible(), "bind a replacement Home owner");
    card = last_child(content);
    *route = 0x3f;
    check(!native_home_refresh(display, 1) && native_is_hidden(card), "factory update navigation hides the Home panel");
    *route = 0;
    check(!native_home_refresh(display, 0) && native_is_hidden(card), "native lock hides Wi-Fi Home content");
    ui.page = 1;
    check(!native_home_refresh(display, 1) && native_is_hidden(card), "network selection hides the Home panel");
    ui.page = 0;
    ui_status(j_parse("{\"ok\":true,\"data\":{\"config\":{\"mode\":\"hotspot\"},\"phase\":\"hotspot\",\"networks\":[]}}"));
    check(!native_home_refresh(display, 1) && native_is_hidden(card), "SIM hotspot retains the original Home presentation");
    j_put(ui.status); ui.status = NULL; ui.online = ui.connected = ui.rates_valid = 0;
}
static void check_lock(native_display *display) {
    const char *fixture="{\"ok\":true,\"data\":{\"config\":{\"mode\":\"repeater\",\"ssid\":\"Fixture\"},\"phase\":\"connected\",\"networks\":[],\"connectivity\":\"online\",\"ipv4\":\"192.0.2.2\"}}";
    ui_status(j_parse(fixture));ui.rates_valid=1;ui_hotspot_status("state=ENABLED\nssid[0]=Travel Wi-Fi\n");
    native_obj *body=lock_fixture(layers[2]);check(body!=NULL,"factory lock geometry fixture");
    native_lvgl.clear_flag(layers[2],NATIVE_HIDDEN);native_lvgl.add_flag(layers[3],NATIVE_HIDDEN);settle();
    check(!native_home_refresh(display,0),"repeater information binds to the native lock");
    native_obj *card=native_child(body,14);check(card&&!native_is_hidden(card),"native lock displays the repeater notice");
    check(!strcmp(native_lvgl.label_get_text(native_child(card,2)),"Fixture")&&
          !strcmp(native_lvgl.label_get_text(native_child(card,3)),"已联网")&&
          !strcmp(native_lvgl.label_get_text(native_child(card,10)),"热点：Travel Wi-Fi"),
          "locked and unlocked screens share upstream, online state and hotspot identity");
    check(native_lvgl.get_style(native_child(card,1),0,NATIVE_STYLE_TEXT_OPACITY)==255,
          "repeater lock text has the same explicit opacity as factory labels");
    /* The factory brings its loading indicator to the front on lock changes. */
    native_lvgl.move_to_index(native_child(body,13),14);
    uint32_t flags;memcpy(&flags,(char *)card+0x30,sizeof flags);
    check(!(flags&2),"the lock notice does not consume long-press input");
    check(!strcmp(native_lvgl.label_get_text(native_child(body,1)),"无SIM卡\n请插入SIM卡"),
          "the original cellular notice remains available for SIM hotspot mode");
    ui.online=0;ui_hotspot_status("state=DISABLED\n");
    check(!native_home_refresh(display,0)&&
          !strcmp(native_lvgl.label_get_text(native_child(card,3)),"需认证或网络受限")&&
          !strcmp(native_lvgl.label_get_text(native_child(card,10)),"热点未开启"),
          "the lock updates limited internet and disabled hotspot states");
    ui.connected=0;strcpy(ui.error,"Wi-Fi status is out of date.");ui_hotspot_status(NULL);
    check(!native_home_refresh(display,0)&&
          !strcmp(native_lvgl.label_get_text(native_child(card,3)),"无法获取状态")&&
          !strcmp(native_lvgl.label_get_text(native_child(card,10)),"热点状态不可用"),
          "unavailable state does not display stale connection or broadcast information");
    *ui.error=0;check(!native_home_refresh(display,0),"refresh the recovered lock status");
    settle();unsigned before=flush_count;
    for(unsigned i=0;i<5;i++)check(!native_home_refresh(display,0),"unchanged lock information refresh");
    settle();check(flush_count==before,"unchanged lock information does not redraw");
    native_lvgl.clear_flag(layers[3],NATIVE_HIDDEN);
    check(!native_home_refresh(display,0)&&native_is_hidden(card),"a factory modal hides the repeater lock notice");
    native_lvgl.add_flag(layers[3],NATIVE_HIDDEN);
    body=lock_fixture(layers[2]);check(body!=NULL,"rebuilt factory lock body");settle();
    check(!native_home_refresh(display,0)&&native_child(body,14)&&!native_child(body,15),
          "factory lock reconstruction creates one fresh repeater notice");
    ui_status(j_parse("{\"ok\":true,\"data\":{\"config\":{\"mode\":\"hotspot\"},\"phase\":\"hotspot\",\"networks\":[]}}"));
    check(!native_home_refresh(display,0)&&native_is_hidden(native_child(body,14)),
          "SIM hotspot reveals the original lock presentation");
    native_lvgl.clear_flag(layers[3],NATIVE_HIDDEN);
    j_put(ui.status);ui.status=NULL;ui.online=ui.connected=ui.rates_valid=0;
}
static void flush(void *driver, const void *area, uint16_t *pixels) {
    (void)area; (void)pixels; flush_count++; native_lvgl.flush_ready(driver);
}
static void *serve_status(void *unused) {
    (void)unused;
    for (;;) {
        int client = accept(status_socket, NULL, NULL);
        check(client >= 0, "accept the real status worker request");
        char request[128]; size_t length = 0;
        for (;;) {
            ssize_t count = read(client, request + length, sizeof request - length - 1);
            check(count >= 0, "read the status request");
            if (!count) break;
            length += (size_t)count;
            check(length < sizeof request - 1, "bounded status request");
        }
        request[length] = 0;
        if (!strcmp(request, "{\"action\":\"scan\",\"body\":{\"band\":\"5g\"}}")) {
            atomic_store(&scan_started, 1);
            struct timespec delay = {.tv_nsec = 300000000}; nanosleep(&delay, NULL);
            const char accepted[] = "{\"ok\":true}";
            check(write(client, accepted, sizeof accepted - 1) == sizeof accepted - 1, "scan acknowledgement");
            close(client); atomic_store(&scan_finished, 1); continue;
        }
        if (!strcmp(request,"{\"action\":\"calls\"}")) {
            const char calls[]="{\"ok\":true,\"data\":{\"items\":[],\"nextOffset\":null}}";
            check(write(client,calls,sizeof calls-1)==sizeof calls-1,"call history reply");close(client);continue;
        }
        check(!strcmp(request, "{\"action\":\"status\"}"), "status RPC contract");
        const char reply[] = "{\"ok\":true,\"data\":{\"config\":{\"mode\":\"repeater\",\"band\":\"5g\",\"ssid\":\"Fixture\"},\"phase\":\"connected\",\"networks\":[],\"connectivity\":\"online\",\"ipv4\":\"192.0.2.2\"}}";
        check(write(client, reply, sizeof reply - 1) == sizeof reply - 1, "send synthetic status");
        close(client); atomic_fetch_add(&status_requests, 1);
    }
    return NULL;
}
static uint32_t timer(void) {
    native_lvgl.timer_handler(); iterations++;
    if (iterations == 50) {
        check(initialized && !failed && control_count == 55, "initialize on the pinned UI thread");
        check(native_is_hidden(launcher->object), "preserve the native lock screen");
        native_lvgl.add_flag(layers[2], NATIVE_HIDDEN); native_lvgl.add_flag(layers[3], NATIVE_HIDDEN);
    }
    if (iterations == 100) {
        check(native_is_hidden(launcher->object), "Home keeps its factory navigation without a repeater overlay");
        check(menu_fixture(layers[0]) != NULL, "construct the native Wi-Fi menu");
        int32_t *route;memcpy(&route, (void *)0xe6fca8, sizeof route);*route = 6;
    }
    if (iterations == 160) {
        check(!native_is_hidden(launcher->object), "show the repeater entry inside the native Wi-Fi menu");
        native_obj *parent;memcpy(&parent, (char *)launcher->object + 8, sizeof parent);
        check(parent == native_child(native_child(layers[0], 3), 0), "the real main loop attaches to the factory list");
        pthread_mutex_lock(&ui.mutex); ui.page = 2; strcpy(ui.password, "synthetic-input"); pthread_mutex_unlock(&ui.mutex);
        native_lvgl.clear_flag(layers[2], NATIVE_HIDDEN);
    }
    if (iterations == 240) {
        check(!failed && ui.page == 0 && !*ui.password, "native relock clears private input");
        FILE *file = fopen("/tmp/openu60-ui.heartbeat", "r"); long pid = 0; unsigned long long current = 0;
        check(file && fscanf(file, "%ld %llu", &pid, &current) == 2, "read UI-thread heartbeat");
        fclose(file); check(pid == getpid() && current >= 3, "heartbeat advances on the real main loop");
        pthread_mutex_lock(&ui.mutex); int online = ui.online; pthread_mutex_unlock(&ui.mutex);
        check(atomic_load(&status_requests) && online, "worker completes RPC despite the factory shutdown image symbol");
        native_lvgl.add_flag(layers[2], NATIVE_HIDDEN);
        native_panel_refresh(1);
        pthread_mutex_lock(&ui.mutex); ui_open(); pthread_mutex_unlock(&ui.mutex);
    }
    if (atomic_load(&scan_started) && !atomic_load(&scan_finished) && !pending_checked) {
        pthread_mutex_lock(&ui.mutex);
        check(!*ui.command && !ui.busy, "exercise the dispatched request before remote busy is visible");
        ui_other(); check(ui.page == 1 && ui_busy(), "keep controls disabled during an in-flight scan request");
        pthread_mutex_unlock(&ui.mutex); pending_checked = 1;
    }
    pthread_mutex_lock(&ui.mutex); int complete = atomic_load(&scan_finished) && !ui_busy();
    if (complete) {
        ui_back();ui_open();
        check(ui.page == 1 && !ui_busy() && !ui.network_count, "cache an empty successful scan after real worker completion");
        ui_other(); check(ui.page == 3, "enable controls after command acknowledgement and fresh status");
    }
    pthread_mutex_unlock(&ui.mutex);
    if (complete) {
        check(pending_checked, "observe the real pending scan interval");
        puts("Native integration: original main loop, real worker RPC, pending scan ownership, UI heartbeat, stock lock/unlock and rate ABI passed");
        fflush(stdout); _Exit(0);
    }
    check(iterations < 1000, "finite command completion");
    return 5;
}
static int probe_main(int argc, char **argv, char **environment) {
    (void)argc; (void)argv; (void)environment;
    check(!failed, "resolve the exact firmware SDK dependencies");
    check_presentation_contract();
    status_socket = socket(AF_UNIX, SOCK_STREAM, 0); check(status_socket >= 0, "status listener socket");
    struct sockaddr_un address = {.sun_family = AF_UNIX}; strcpy(address.sun_path, UI_SOCKET);
    check(!bind(status_socket, (struct sockaddr *)&address, sizeof address) && !listen(status_socket, 2), "isolated local status listener");
    pthread_t server; check(!pthread_create(&server, NULL, serve_status, NULL), "status server thread");
    setenv("LD_PRELOAD", "synthetic-child-marker", 1); initialize();
    check(getenv("LD_PRELOAD") == NULL, "child clients cannot inherit the extension");
    usleep(1000); check(!initialized, "SDK/startup sleeps cannot enter LVGL");
    pthread_mutex_lock(&ui.mutex); ui.rates_valid = 1; ui.rx_rate = 0x123456789ULL; ui.tx_rate = 0x234567890ULL; pthread_mutex_unlock(&ui.mutex);
    uint64_t rates[3] = {0, 0, 0xaabbccddeeff0011ULL};
    check(!ZTD_GetRealTimeRxThrpt(&rates[0]) && !ZTD_GetRealTimeTxThrpt(&rates[1]) &&
          rates[0] == 0x123456789ULL && rates[1] == 0x234567890ULL && rates[2] == 0xaabbccddeeff0011ULL, "SDK throughput writes exactly 64-bit byte rates");
    pthread_mutex_lock(&ui.mutex); ui.rates_valid = 0; pthread_mutex_unlock(&ui.mutex);
    native_lvgl.init();
    check(!font_fixture(), "initialize the native Chinese font fixture");
    static _Alignas(16) unsigned char driver[0x98], buffer[0x28]; static uint16_t pixels[320 * 480];
    native_lvgl.driver_init(driver); native_lvgl.buffer_init(buffer, pixels, NULL, 320 * 480);
    void *buf = buffer; memcpy(driver + 0x10, &buf, sizeof buf);
    void (*callback)(void *, const void *, uint16_t *) = flush; memcpy(driver + 0x20, &callback, sizeof callback);
    native_display *display = native_lvgl.register_display(driver); check(display != NULL, "memory display");
    native_obj *screen = native_active_screen(display);
    for (unsigned i = 0; i < 4; i++) {
        layers[i] = native_lvgl.object_create(screen); check(layers[i] != NULL, "stock layout fixture");
        native_lvgl.set_position(layers[i], 0, 0); native_lvgl.set_size(layers[i], 320, 480);
    }
    check_home(display);
    check_lock(display);
    /* Execute the original ELF's main-loop instructions, retaining its actual
     * usleep return address. No original DRM/input initialization is executed. */
    __asm__ volatile("mov x19, %0\nmov x20, %1\nbr %2" : :
        "r"(usleep), "r"(timer), "r"((void *)0x40fc28) : "x19", "x20", "memory");
    __builtin_unreachable();
}
int __libc_start_main(int (*original)(int, char **, char **), int argc, char **argv,
                     void (*init)(void), void (*fini)(void), void (*ldso)(void)) {
    (void)original;
    int (*real)(int (*)(int, char **, char **), int, char **, void (*)(void), void (*)(void), void (*)(void));
    *(void **)&real = dlsym(RTLD_NEXT, "__libc_start_main");
    if (!real) _Exit(125);
    return real(probe_main, argc, argv, init, fini, ldso);
}
