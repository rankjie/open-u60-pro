#include "ui.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>
#include <time.h>

static uint64_t test_ms=100000;
int clock_gettime(clockid_t clock,struct timespec *now) {
    assert(clock==CLOCK_MONOTONIC);
    now->tv_sec=(time_t)(test_ms/1000);now->tv_nsec=(long)(test_ms%1000)*1000000;
    return 0;
}
static void complete_scan(const char *fixture,const char *error) {
    ui_clear(ui.command,sizeof ui.command);ui.in_flight=0;
    struct json_object *reply=j_parse(fixture),*data=j_get(reply,"data");
    j_add(data,"scan_error",j_text(error));ui_status(reply);
}
static void check_scan_cache(const char *fixture) {
    ui_open();assert(ui_busy()&&strstr(ui.command,"scan"));
    char pending[sizeof ui.command];strcpy(pending,ui.command);
    ui_back();ui_open();assert(!strcmp(pending,ui.command));
    test_ms+=2000;
    /* Polling before command acknowledgement must not populate the cache. */
    ui_status(j_parse(fixture));assert(ui_busy());
    struct json_object *running=j_parse(fixture);
    j_add(j_get(running,"data"),"busy",json_object_new_boolean(1));
    ui_clear(ui.command,sizeof ui.command);ui.in_flight=0;ui_status(running);
    test_ms+=6000;
    ui_back();ui_open();assert(ui_busy()&&!*ui.command);
    complete_scan(fixture,"");assert(!ui_busy());
    ui_back();ui_open();assert(ui.page==1&&ui.network_count==1&&!ui_busy());
    test_ms+=29999;
    ui_status(j_parse(fixture));
    ui_back();ui_open();assert(!ui_busy());
    test_ms++;
    ui_back();ui_open();assert(ui_busy()&&strstr(ui.command,"scan"));
    complete_scan(fixture,"");
    /* The explicit Scan control refreshes even immediately after success. */
    ui_band(ui.band);assert(ui_busy()&&strstr(ui.command,"scan"));
    complete_scan(fixture,"Synthetic scan failure");
    ui_back();ui_open();assert(ui_busy()&&strstr(ui.command,"scan"));
    /* Empty successful scans are cached, too. */
    struct json_object *empty=j_parse(fixture);
    j_add(j_get(empty,"data"),"networks",json_object_new_array());
    ui_clear(ui.command,sizeof ui.command);ui.in_flight=0;ui_status(empty);
    ui_back();ui_open();assert(!ui_busy()&&ui.network_count==0);
    /* A different band must fetch its own results. */
    ui_band(2);assert(ui_busy()&&strstr(ui.command,"2g"));
    complete_scan(fixture,"");assert(ui.network_count==1);
    ui_back();ui_open();assert(!ui_busy()&&ui.band==2);
    ui_band(5);assert(ui_busy()&&strstr(ui.command,"5g"));
    complete_scan(fixture,"");
    test_ms+=30000;
}
static void check_hotspot_confirmation(const char *fixture) {
    ui.page=1;ui_hotspot();
    assert(ui.page==5&&!*ui.command&&!ui_busy());
    ui_click(80,180);assert(ui.page==5&&!*ui.command);
    ui_click(94,312);assert(ui.page==1&&!*ui.command);
    ui_click(246,100);assert(ui.page==5&&!*ui.command);
    ui_back();assert(ui.page==1&&!*ui.command);
    ui.busy=1;ui_hotspot();assert(ui.page==1&&!*ui.command);ui.busy=0;
    ui_hotspot();ui.busy=1;ui_confirm_hotspot();
    assert(ui.page==5&&!*ui.command);ui.busy=0;
    ui_click(226,312);assert(ui.page==1&&ui_busy());
    struct json_object *request=j_parse(ui.command);
    assert(request&&!strcmp(j_string(j_get(request,"action")),"apply"));
    assert(!strcmp(j_string(j_get(j_get(request,"body"),"mode")),"hotspot"));j_put(request);
    char pending[sizeof ui.command];strcpy(pending,ui.command);
    ui_confirm_hotspot();assert(!strcmp(pending,ui.command));
    ui_clear(ui.command,sizeof ui.command);ui.in_flight=ui.busy=0;
    ui_hotspot();assert(ui.page==5);
    struct json_object *changed=j_parse(fixture);
    j_add(j_get(j_get(changed,"data"),"config"),"mode",j_text("hotspot"));ui_status(changed);
    assert(ui.page==1&&!*ui.command);ui_confirm_hotspot();assert(!*ui.command);
    struct json_object *offline=j_parse(fixture),*data=j_get(offline,"data");
    j_add(data,"ipv4",j_text(""));j_add(data,"phase",j_text("failed"));ui_status(offline);
    assert(!ui.connected);ui_hotspot();assert(ui.page==5&&!*ui.command);
    ui_back();ui_status(j_parse(fixture));
}

int main(void) {
    /* Keep the host ABI library loaded for the same dlsym path used on-device. */
    struct json_object *keep=json_object_new_object();
    assert(keep&&ui_json_init()==0);
    ui_hotspot_status("state=ENABLED\nssid[0]=Travel Wi-Fi\nssid[1]=Guest\n");
    assert(ui.hotspot_state==UI_HOTSPOT_ENABLED&&!strcmp(ui.hotspot_ssid,"Travel Wi-Fi"));
    ui_hotspot_status("state=ENABLED\nssid[0]=家里的热点\n");
    assert(ui.hotspot_state==UI_HOTSPOT_ENABLED&&!strcmp(ui.hotspot_ssid,"家里的热点"));
    ui_hotspot_status("state=ENABLED\nssid[0]=12345678901234567890123456789012\n");
    assert(ui.hotspot_state==UI_HOTSPOT_ENABLED&&strlen(ui.hotspot_ssid)==32);
    ui_hotspot_status("state=DISABLED\nssid[0]=Prior network\n");
    assert(ui.hotspot_state==UI_HOTSPOT_DISABLED&&!*ui.hotspot_ssid);
    const char *invalid[]={NULL,"FAIL\n","state=ENABLED\n","state=ENABLED\nssid[0]=\n",
        "state=ENABLED\nssid[0]=12345678901234567890123456789012345\n"};
    for(unsigned i=0;i<sizeof invalid/sizeof *invalid;i++) {
        ui_hotspot_status(invalid[i]);
        assert(ui.hotspot_state==UI_HOTSPOT_UNKNOWN&&!*ui.hotspot_ssid);
    }
    const char *fixture="{\"ok\":true,\"data\":{\"config\":{\"mode\":\"repeater\",\"band\":\"5g\",\"ssid\":\"Home\",\"security\":\"mixed\",\"has_password\":true,\"mac_mode\":\"factory\",\"clone_mac\":\"\"},\"phase\":\"connected\",\"busy\":false,\"connectivity\":\"online\",\"ipv4\":\"192.0.2.2\",\"networks\":[{\"ssid\":\"Home\",\"security\":\"mixed\",\"supported\":true,\"frequency\":5200,\"signal\":-60},{\"ssid\":\"Home\",\"security\":\"mixed\",\"supported\":true,\"frequency\":5200,\"signal\":-35},{\"ssid\":\"Home\",\"security\":\"open\",\"supported\":true,\"frequency\":5200,\"signal\":-10},{\"ssid\":\"Two\",\"security\":\"open\",\"supported\":true,\"frequency\":2412,\"signal\":-20}]}}";
    ui_status(j_parse(fixture));
    assert(ui.online&&ui.connected&&ui.network_count==1&&ui.networks[0].signal==-35);
    check_hotspot_confirmation(fixture);
    check_scan_cache(fixture);
    ui.page=1;ui_click(30,170);
    assert(ui.page==2&&!strcmp(ui.ssid,"Home"));
    ui_click(100,220);
    struct json_object *command=j_parse(ui.command),*body=j_get(command,"body");
    assert(command&&!strcmp(j_string(j_get(command,"action")),"apply"));
    assert(!strcmp(j_string(j_get(body,"mode")),"repeater")&&!j_get(body,"password"));
    assert(ui.page==1&&ui.busy);j_put(command);ui_clear(ui.command,sizeof ui.command);ui.in_flight=0;ui.busy=0;
    ui_click(50,452);assert(ui.page==3&&!*ui.ssid&&!strcmp(ui.security,"auto"));
    ui_click(100,220);assert(!*ui.command&&strstr(ui.error,"network name"));
    strcpy(ui.ssid,"Hidden");strcpy(ui.password,"synthetic-password");ui_click(100,220);
    command=j_parse(ui.command);body=j_get(command,"body");
    assert(!strcmp(j_string(j_get(body,"security")),"auto"));
    assert(!strcmp(j_string(j_get(body,"password")),"synthetic-password"));
    assert(!*ui.password);j_put(command);ui_clear(ui.command,sizeof ui.command);ui.in_flight=0;ui.busy=0;
    ui.page=1;ui_click(40,125);
    assert(ui.band==2&&ui.network_count==1&&!strcmp(ui.networks[0].ssid,"Two"));
    command=j_parse(ui.command);assert(!strcmp(j_string(j_get(command,"action")),"scan"));j_put(command);
    ui_status(j_parse("{\"ok\":true,\"data\":{}}"));assert(!ui.connected&&!ui.online&&strstr(ui.error,"Invalid"));
    j_put(ui.status);json_object_put(keep);
    puts("Native Wi-Fi mode confirmation, scan cache, grouping, join and failure behavior passed");
    return 0;
}
