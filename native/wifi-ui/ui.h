#ifndef OPENU60_WIFI_UI_H
#define OPENU60_WIFI_UI_H
#include <stdint.h>
#include <stddef.h>
#include <pthread.h>
#include <json-c/json.h>
#define UI_W 320
#define UI_H 480
#ifndef UI_SOCKET
#define UI_SOCKET "/data/openu60-wifi/ui.sock"
#endif
#define UI_MAX 65536
struct ui_network { char ssid[129], security[16]; int signal; };
struct ui_call {char number[64],state[16],direction[12];uint64_t started_at,answered_at;};
enum ui_hotspot_state {UI_HOTSPOT_UNKNOWN, UI_HOTSPOT_DISABLED, UI_HOTSPOT_ENABLED};
struct ui_state {
    pthread_mutex_t mutex;
    struct json_object *status;
    int page, band, offset, field, symbols, shift;
    int online, connected, busy, in_flight, has_password, rates_valid;
    enum ui_hotspot_state hotspot_state;
    char hotspot_ssid[129];
    uint64_t rx_rate, tx_rate;
    uint64_t status_at_ms;
    uint64_t scan_at_ms;
    int scan_cached_band, scan_pending_band;
    char ssid[129], password[257], security[16], error[256];
    char command[8192];
    char connection_code[64], connection_server[512], connection_error[128];
    struct ui_network networks[128];
    int network_count;
    struct ui_call calls[100];
    int call_count, calls_valid;
    char calls_error[256];
};
extern struct ui_state ui;
extern struct json_object *(*j_parse)(const char *);
extern struct json_object *(*j_get)(const struct json_object *, const char *);
extern const char *(*j_string)(struct json_object *);
extern int (*j_bool)(const struct json_object *);
extern int64_t (*j_int)(const struct json_object *);
extern size_t (*j_length)(const struct json_object *);
extern struct json_object *(*j_at)(const struct json_object *, size_t);
extern int (*j_put)(struct json_object *);
extern struct json_object *(*j_new)(void);
extern struct json_object *(*j_text)(const char *);
extern struct json_object *(*j_number)(int64_t);
extern int (*j_add)(struct json_object *, const char *, struct json_object *);
extern const char *(*j_encode)(struct json_object *, int);
int ui_json_init(void);
void ui_clear(void *data, size_t size);
void ui_status(struct json_object *response);
void ui_hotspot_status(const char *response);
void ui_calls(struct json_object *response);
int ui_command(const char *action, struct json_object *body);
int ui_busy(void);
void ui_click(int x, int y);
/* Controller calls run while holding ui.mutex; they never draw or log input. */
void ui_open(void);
void ui_back(void);
void ui_band(int band);
void ui_select(int index);
void ui_other(void);
void ui_connect(void);
void ui_hotspot(void);
void ui_confirm_hotspot(void);
void ui_key(int character);
void ui_delete(void);
const char *ui_keys(void);
int ui_saved_password(void);
void *ui_worker(void *unused);
#endif
