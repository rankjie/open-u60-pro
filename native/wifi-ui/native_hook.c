#define _GNU_SOURCE
#include "native_panel.h"
#include "native_layout.h"
#include "native_home.h"
#include "native_calls.h"
#include "native_health.h"
#include "ui.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <sys/mman.h>
#include <unistd.h>

static int (*original_usleep)(useconds_t);
static int (*original_dial)(int *);
static int (*original_sim)(int *);
static int (*original_rx)(uint64_t *);
static int (*original_tx)(uint64_t *);
static pthread_t ui_thread;
static int initialized, failed;
static uint64_t previous_tick, sequence, home_wait_started, panel_wait_started, calls_wait_started;
static uint64_t factory_rate_reads, factory_update_checks;
static unsigned factory_rate_views;
static native_obj *stock_screen, *stock_lock;

static int lock_rates_ready(void) {
    pthread_mutex_lock(&ui.mutex);
    int ready = ui.connected && ui.rates_valid;
    pthread_mutex_unlock(&ui.mutex);
    return ready;
}
static int read_lock_connection(uintptr_t caller, void *model) {
    /* The lock's cached cellular-model gate otherwise discards measured Wi-Fi
     * rates. This call is presentation-only; the model itself is never changed. */
    if (caller == 0x4b40cc && lock_rates_ready()) return 2;
    int (*original)(void *) = (void *)0x4ca204;
    return original(model);
}
static int lock_connection(void *model) {
    return read_lock_connection((uintptr_t)__builtin_return_address(0), model);
}
static int bind_lock_connection(void) {
    /* This private getter has a local RELATIVE relocation, so normal symbol
     * interposition cannot reach it. Change only this process's pinned GOT
     * entry, and immediately restore RELRO. A factory restart maps the original
     * entry again; neither executable bytes nor persistent state are patched. */
    void *original; memcpy(&original, (void *)0xe6b460, sizeof original);
    if (original == (void *)lock_connection) return 0;
    if (original != (void *)0x4ca204) return -1;
    long page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0) return -1;
    uintptr_t page = 0xe6b460 - 0xe6b460 % (uintptr_t)page_size;
    if (mprotect((void *)page, (size_t)page_size, PROT_READ | PROT_WRITE)) return -1;
    int (*replacement)(void *) = lock_connection;
    memcpy((void *)0xe6b460, &replacement, sizeof replacement);
    /* Never enter the UI loop if restoring the original page protection fails.
     * The independent guardian treats this exit as a failed candidate. */
    if (mprotect((void *)page, (size_t)page_size, PROT_READ)) _Exit(126);
    return 0;
}

static void fail(enum native_fault code) {
    failed = 1;
    /* Fixed codes distinguish an intentional fail-closed path from a blocked
     * UI thread. Neither UI text nor configuration belongs in recovery logs. */
    char bytes[64];
    int length = snprintf(bytes, sizeof bytes, "%ld %u\n", (long)getpid(), (unsigned)code);
    const char *temporary = NATIVE_FAULT_PATH ".next";
    int fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return;
    int ok = write(fd, bytes, (size_t)length) == length;
    if (close(fd)) ok = 0;
    if (!ok || rename(temporary, NATIVE_FAULT_PATH)) unlink(temporary);
}

static uint64_t monotonic_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) return 0;
    return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
}
static int heartbeat(void) {
    char bytes[96]; int length = snprintf(bytes, sizeof bytes, "%ld %llu\n", (long)getpid(), (unsigned long long)++sequence);
    int fd = open("/tmp/openu60-ui.heartbeat", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return -1;
    int ok = write(fd, bytes, (size_t)length) == length;
    if (close(fd)) ok = 0;
    return ok ? 0 : -1;
}
static int publish_state(int unlocked) {
    char bytes[512];
    pthread_mutex_lock(&ui.mutex);
    int length = snprintf(bytes, sizeof bytes,
        "{\"pid\":%ld,\"sequence\":%llu,\"locked\":%s,\"page\":%d,\"busy\":%s,\"online\":%s,\"ratesValid\":%s,\"rxBytesPerSecond\":%llu,\"txBytesPerSecond\":%llu,\"factoryRateReads\":%llu,\"factoryRateViews\":%u,\"factoryUpdateChecks\":%llu,\"wifiHomeVisible\":%s,\"factoryForm\":%d}\n",
        (long)getpid(), (unsigned long long)sequence, unlocked ? "false" : "true", ui.page,
        ui_busy() ? "true" : "false",
        ui.online ? "true" : "false", ui.rates_valid ? "true" : "false",
        (unsigned long long)ui.rx_rate, (unsigned long long)ui.tx_rate,
        (unsigned long long)factory_rate_reads, factory_rate_views, (unsigned long long)factory_update_checks,
        native_home_visible() ? "true" : "false", native_current_form());
    pthread_mutex_unlock(&ui.mutex);
    const char *temporary = "/tmp/openu60-native-ui.status.next";
    int fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return -1;
    int ok = write(fd, bytes, (size_t)length) == length;
    if (close(fd)) ok = 0;
    if (!ok || rename(temporary, "/tmp/openu60-native-ui.status")) {unlink(temporary); return -1;}
    return 0;
}
static void tick(void) {
    if (failed) return;
    native_display *display = native_lvgl.default_display();
    if (!native_lvgl.is_initialized() || !display) return;
    if (!initialized) {
        ui_thread = pthread_self();
        if (ui_json_init()) {fail(NATIVE_FAULT_JSON); return;}
        native_obj *top; memcpy(&top, (char *)display + 0x38, sizeof top);
        if (native_panel_create(top)) {fail(NATIVE_FAULT_PANEL); return;}
        pthread_attr_t attributes;
        if (pthread_attr_init(&attributes)) {fail(NATIVE_FAULT_WORKER); return;}
        int result = pthread_attr_setstacksize(&attributes, 256 * 1024);
        pthread_t worker;
        if (!result) result = pthread_create(&worker, &attributes, ui_worker, NULL);
        pthread_attr_destroy(&attributes);
        if (result) {fail(NATIVE_FAULT_WORKER); return;}
        pthread_detach(worker); initialized = 1;
    }
    if (!pthread_equal(ui_thread, pthread_self())) return;
    uint64_t now = monotonic_ms();
    if (!now) {fail(NATIVE_FAULT_CLOCK); return;}
    if (now - previous_tick < 200) return;
    pthread_mutex_lock(&ui.mutex);
    if (ui.status_at_ms && now - ui.status_at_ms >= 5000) {
        ui.online = ui.connected = ui.rates_valid = 0;
        ui.hotspot_state = UI_HOTSPOT_UNKNOWN;*ui.hotspot_ssid = 0;
        snprintf(ui.error, sizeof ui.error, "Wi-Fi status is out of date.");
    }
    pthread_mutex_unlock(&ui.mutex);
    int unlocked = native_stock_unlocked(display, &stock_screen, &stock_lock);
    int home_result = native_home_refresh(display, unlocked);
    if (!home_result) home_wait_started = 0;
    else if (!home_wait_started) home_wait_started = now;
    if (home_result < 0) {fail(NATIVE_FAULT_HOME); return;}
    if (home_result > 0 && now - home_wait_started >= 20000) {fail(NATIVE_FAULT_HOME_LAYOUT); return;}
    int panel_result = native_panel_refresh(unlocked);
    if (!panel_result) panel_wait_started = 0;
    else if (!panel_wait_started) panel_wait_started = now;
    if (panel_result < 0 || (panel_result > 0 && now - panel_wait_started >= 20000)) {fail(NATIVE_FAULT_PANEL); return;}
    int calls_result=native_calls_refresh(display,unlocked);
    if(!calls_result)calls_wait_started=0;
    else if(!calls_wait_started)calls_wait_started=now;
    if(calls_result<0||(calls_result>0&&now-calls_wait_started>=20000)){fail(NATIVE_FAULT_PANEL);return;}
    if (heartbeat() || publish_state(unlocked)) {fail(NATIVE_FAULT_HEALTH); return;}
    previous_tick = now;
}
int usleep(useconds_t duration) {
    if (!original_usleep) *(void **)&original_usleep = dlsym(RTLD_NEXT, "usleep");
    /* The pinned main loop calls this immediately after its real LVGL handler.
     * Startup waits, input reads, DRM calls and SDK worker sleeps never enter it. */
    if ((uintptr_t)__builtin_return_address(0) == NATIVE_UI_SLEEP_RETURN) tick();
    if (!original_usleep) {errno = ENOSYS; return -1;}
    return original_usleep(duration);
}
static int read_dial_status(uintptr_t caller, int *value) {
    int update_check = caller == 0x509ac0 || caller == 0x509f98 || caller == 0x50e984 || caller == 0x50c7c8;
    pthread_mutex_lock(&ui.mutex); int online = ui.online;
    if (update_check) factory_update_checks++;
    pthread_mutex_unlock(&ui.mutex);
    /* Only the inspected update checks use Wi-Fi availability as internet state.
     * Cellular settings keep their actual modem dial state. */
    if (((update_check && online) || (caller == 0x4b4120 && lock_rates_ready())) && value) {*value = 2; return 0;}
    return original_dial ? original_dial(value) : -1;
}
int ZTD_GetDialStatus(int *value) {
    return read_dial_status((uintptr_t)__builtin_return_address(0), value);
}
static int read_sim_state(uintptr_t caller, int *value) {
    /* The result is local to the lock's numeric formatter. All SIM settings
     * and modem consumers still call the actual SDK with its real SIM state. */
    if (caller == 0x4b4074 && lock_rates_ready() && value) {*value = 4; return 0;}
    return original_sim ? original_sim(value) : -1;
}
int ZTD_GetActiveSimState(int *value) {
    return read_sim_state((uintptr_t)__builtin_return_address(0), value);
}
static void record_rate_reader(uintptr_t caller) {
    /* Numeric call-site coverage distinguishes a live station sample from the
     * factory actually reading it. The pinned views contain no private input. */
    static const uintptr_t starts[] = {0x4adf7c, 0x4b3cf8, 0x4bbe94, 0x4cae18};
    static const uintptr_t ends[] = {0x4ae624, 0x4b4588, 0x4bc5dc, 0x4cb01c};
    factory_rate_reads++;
    for (unsigned i = 0; i < 4; i++) if (caller >= starts[i] && caller < ends[i]) factory_rate_views |= 1u << i;
}
int ZTD_GetRealTimeRxThrpt(uint64_t *value) {
    pthread_mutex_lock(&ui.mutex); record_rate_reader((uintptr_t)__builtin_return_address(0));
    int valid = ui.rates_valid; uint64_t rate = ui.rx_rate; pthread_mutex_unlock(&ui.mutex);
    if (valid && value) {*value = rate; return 0;}
    return original_rx ? original_rx(value) : -1;
}
int ZTD_GetRealTimeTxThrpt(uint64_t *value) {
    pthread_mutex_lock(&ui.mutex); record_rate_reader((uintptr_t)__builtin_return_address(0));
    int valid = ui.rates_valid; uint64_t rate = ui.tx_rate; pthread_mutex_unlock(&ui.mutex);
    if (valid && value) {*value = rate; return 0;}
    return original_tx ? original_tx(value) : -1;
}
__attribute__((constructor)) static void initialize(void) {
    /* The factory process spawns normal firmware clients; the extension must not
     * be inherited by any of them. No native object is touched during loading. */
    unsetenv("LD_PRELOAD");
    *(void **)&original_usleep = dlsym(RTLD_NEXT, "usleep");
    *(void **)&original_dial = dlsym(RTLD_NEXT, "ZTD_GetDialStatus");
    *(void **)&original_sim = dlsym(RTLD_NEXT, "ZTD_GetActiveSimState");
    *(void **)&original_rx = dlsym(RTLD_NEXT, "ZTD_GetRealTimeRxThrpt");
    *(void **)&original_tx = dlsym(RTLD_NEXT, "ZTD_GetRealTimeTxThrpt");
    if (!original_usleep || !original_dial || !original_sim || !original_rx || !original_tx || bind_lock_connection())
        fail(NATIVE_FAULT_SYMBOLS);
}
