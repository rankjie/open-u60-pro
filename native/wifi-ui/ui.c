#define _GNU_SOURCE
#include "ui.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>
#include <time.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>

struct ui_state ui = {.mutex=PTHREAD_MUTEX_INITIALIZER, .band=5};
struct json_object *(*j_parse)(const char *);
struct json_object *(*j_get)(const struct json_object *, const char *);
const char *(*j_string)(struct json_object *);
int (*j_bool)(const struct json_object *);
int64_t (*j_int)(const struct json_object *);
size_t (*j_length)(const struct json_object *);
struct json_object *(*j_at)(const struct json_object *, size_t);
int (*j_put)(struct json_object *);
struct json_object *(*j_new)(void);
struct json_object *(*j_text)(const char *);
struct json_object *(*j_number)(int64_t);
int (*j_add)(struct json_object *, const char *, struct json_object *);
const char *(*j_encode)(struct json_object *, int);
static int (*socket_shutdown)(int, int);

int ui_json_init(void) {
#define LOAD(var,name) do { *(void **)(&var)=dlsym(RTLD_DEFAULT,name); if (!var) return -1; } while (0)
    LOAD(j_parse,"json_tokener_parse"); LOAD(j_get,"json_object_object_get");
    LOAD(j_string,"json_object_get_string"); LOAD(j_bool,"json_object_get_boolean");
    LOAD(j_int,"json_object_get_int64"); LOAD(j_length,"json_object_array_length");
    LOAD(j_at,"json_object_array_get_idx"); LOAD(j_put,"json_object_put");
    LOAD(j_new,"json_object_new_object"); LOAD(j_text,"json_object_new_string");
    LOAD(j_number,"json_object_new_int64"); LOAD(j_add,"json_object_object_add");
    LOAD(j_encode,"json_object_to_json_string_ext");
#undef LOAD
    /* The pinned factory executable exports its shutdown image as data. Skip
     * that executable's symbol when resolving the socket function. */
    *(void **)&socket_shutdown=dlsym(RTLD_NEXT,"shutdown");
    if(!socket_shutdown)return -1;
    return 0;
}
void ui_clear(void *data,size_t size) { volatile unsigned char *p=data; while(size--) *p++=0; }
static const char *text(struct json_object *obj,const char *key) {
    struct json_object *v=j_get(obj,key); const char *s=v?j_string(v):NULL; return s?s:"";
}
static void copy(char *out,size_t size,const char *value) { snprintf(out,size,"%s",value?value:""); }
static uint64_t monotonic_ms(void) {
    struct timespec now;clock_gettime(CLOCK_MONOTONIC,&now);
    return (uint64_t)now.tv_sec*1000+(uint64_t)now.tv_nsec/1000000;
}
static struct json_object *config(void) { return ui.status?j_get(j_get(ui.status,"data"),"config"):NULL; }
static int same_network(void) {
    struct json_object *c=config();
    return c && j_bool(j_get(c,"has_password")) && !strcmp(text(c,"ssid"),ui.ssid)
        && (!strcmp(ui.security,"auto") || !strcmp(text(c,"security"),ui.security));
}
int ui_saved_password(void) {return same_network();}
static int strongest(const void *a,const void *b) {
    const struct ui_network *x=a,*y=b;
    return x->signal==y->signal?strcmp(x->ssid,y->ssid):y->signal-x->signal;
}
static void networks(void) {
    ui.network_count=0;
    struct json_object *list=ui.status?j_get(j_get(ui.status,"data"),"networks"):NULL;
    if (!list) return;
    for(size_t i=0;i<j_length(list);i++) {
        struct json_object *n=j_at(list,i);
        int freq=(int)j_int(j_get(n,"frequency"));
        if (!j_bool(j_get(n,"supported")) || (ui.band==2?freq>=2500:freq<4900)) continue;
        const char *ssid=text(n,"ssid"),*security=text(n,"security");
        if (!*ssid || strlen(ssid)>32) continue;
        int at=ui.network_count;
        for(int k=0;k<ui.network_count;k++) if(!strcmp(ui.networks[k].ssid,ssid)) {at=k;break;}
        if(at==128) continue;
        int signal=(int)j_int(j_get(n,"signal"));
        if(at<ui.network_count) {
            int old_open=!strcmp(ui.networks[at].security,"open"),new_open=!strcmp(security,"open");
            if((!old_open&&new_open) || (old_open==new_open && signal<=ui.networks[at].signal)) continue;
        } else ui.network_count++;
        copy(ui.networks[at].ssid,sizeof ui.networks[at].ssid,ssid);
        copy(ui.networks[at].security,sizeof ui.networks[at].security,security);
        ui.networks[at].signal=signal;
    }
    qsort(ui.networks,(size_t)ui.network_count,sizeof ui.networks[0],strongest);
    if(ui.offset>=ui.network_count) ui.offset=0;
}
void ui_status(struct json_object *response) {
    if(!j_bool(j_get(response,"ok"))) { copy(ui.error,sizeof ui.error,text(response,"error")); j_put(response); return; }
    struct json_object *data=j_get(response,"data"),*c=data?j_get(data,"config"):NULL;
    if(!data||!c||!j_get(data,"phase")||!j_get(data,"networks")) {
        ui.connected=ui.online=ui.busy=ui.rates_valid=0;copy(ui.error,sizeof ui.error,"Invalid local Wi-Fi status.");j_put(response);return;
    }
    ui.busy=j_bool(j_get(data,"busy"));
    ui.connected=!strcmp(text(c,"mode"),"repeater") && *text(data,"ipv4") && strcmp(text(data,"phase"),"failed");
    ui.online=ui.connected && !strcmp(text(data,"connectivity"),"online");
    ui.status_at_ms=monotonic_ms();
    /* A scan is fresh only after acknowledgement and a completed status poll. */
    if(ui.scan_pending_band && !ui.in_flight && !ui.busy) {
        if(!*text(data,"scan_error")) {
            ui.scan_at_ms=ui.status_at_ms;ui.scan_cached_band=ui.scan_pending_band;
        }
        ui.scan_pending_band=0;
    }
    if(!strcmp(ui.error,"Wi-Fi status is out of date."))*ui.error=0;
    if(ui.status) j_put(ui.status);
    ui.status=response; networks();
    if(ui.page==5&&strcmp(text(c,"mode"),"repeater"))ui.page=1;
}
int ui_busy(void) {return ui.busy || ui.in_flight || *ui.command || ui.scan_pending_band;}
int ui_command(const char *action,struct json_object *body) {
    if(ui_busy()) { copy(ui.error,sizeof ui.error,"Wait for the current Wi-Fi operation."); if(body)j_put(body); return -1; }
    struct json_object *request=j_new();
    if(!request) { if(body)j_put(body); return -1; }
    j_add(request,"action",j_text(action)); if(body)j_add(request,"body",body);
    const char *encoded=j_encode(request,JSON_C_TO_STRING_PLAIN);
    if(!encoded || strlen(encoded)>=sizeof ui.command) { j_put(request); copy(ui.error,sizeof ui.error,"Wi-Fi request is too large."); return -1; }
    copy(ui.command,sizeof ui.command,encoded); ui.in_flight=1; j_put(request); *ui.error=0; return 0;
}
static void scan(void) {
    struct json_object *b=j_new();j_add(b,"band",j_text(ui.band==2?"2g":"5g"));
    if(!ui_command("scan",b)) {ui.scan_pending_band=ui.band;ui.scan_cached_band=0;}
}
static void join_network(void) {
    if(!*ui.ssid) {copy(ui.error,sizeof ui.error,"Enter the network name.");return;}
    int saved=same_network() && !*ui.password;
    if(strcmp(ui.security,"open") && strcmp(ui.security,"auto") && !saved && !*ui.password) {
        copy(ui.error,sizeof ui.error,"Enter the Wi-Fi password.");return;
    }
    struct json_object *b=j_new(),*c=config();
    j_add(b,"mode",j_text("repeater"));j_add(b,"band",j_text(ui.band==2?"2g":"5g"));j_add(b,"ssid",j_text(ui.ssid));
    j_add(b,"security",j_text(saved?text(c,"security"):ui.security));
    if(!saved)j_add(b,"password",j_text(ui.password));
    if(c) {
        j_add(b,"mac_mode",j_text(text(c,"mac_mode")));j_add(b,"clone_mac",j_text(text(c,"clone_mac")));
        if(j_get(c,"ttl")) j_add(b,"ttl",j_number(j_int(j_get(c,"ttl"))));
    }
    if(!ui_command("apply",b)) {ui_clear(ui.password,sizeof ui.password);ui.page=1;ui.busy=1;}
}
const char *ui_keys(void) {
    if(ui.symbols) return ui.shift?"~`|\\<>;:'\",./?":"1234567890!@#$%^&*()-_=+[]{}";
    return ui.shift?"QWERTYUIOPASDFGHJKLZXCVBNM":"qwertyuiopasdfghjklzxcvbnm";
}
void ui_open(void) {
    ui.page=1;ui.offset=0;*ui.error=0;
    if(!ui_busy() && (ui.scan_cached_band!=ui.band || monotonic_ms()-ui.scan_at_ms>=30000))scan();
}
void ui_back(void) {ui_clear(ui.password,sizeof ui.password);ui.page=ui.page==1?0:1;*ui.error=0;}
void ui_band(int band) {if((band!=2&&band!=5)||ui_busy())return;ui.band=band;ui.offset=0;networks();scan();}
void ui_select(int index) {
    if(ui_busy()||index<0||index>=ui.network_count)return;
    copy(ui.ssid,sizeof ui.ssid,ui.networks[index].ssid);
    copy(ui.security,sizeof ui.security,ui.networks[index].security);
    ui_clear(ui.password,sizeof ui.password);ui.page=2;ui.field=1;ui.shift=ui.symbols=0;
}
void ui_other(void) {
    if(ui_busy())return;
    ui.page=3;ui.field=0;ui.shift=ui.symbols=0;*ui.ssid=0;
    ui_clear(ui.password,sizeof ui.password);copy(ui.security,sizeof ui.security,"auto");
}
void ui_connect(void) {if(!ui_busy())join_network();}
void ui_hotspot(void) {
    struct json_object *c=config();
    if(ui.page==1&&!ui_busy()&&c&&!strcmp(text(c,"mode"),"repeater")) {ui.page=5;*ui.error=0;}
}
void ui_calls(struct json_object *response) {
    ui.call_count=0;ui.calls_valid=0;
    if(!response||!j_bool(j_get(response,"ok"))) {
        copy(ui.calls_error,sizeof ui.calls_error,response?text(response,"error"):"Calling service is unavailable");return;
    }
    struct json_object *data=j_get(response,"data"),*items=data?j_get(data,"items"):NULL;
    if(!items) {copy(ui.calls_error,sizeof ui.calls_error,"Invalid call history");return;}
    for(size_t i=0;i<j_length(items)&&i<100;i++) {
        struct json_object *item=j_at(items,i);struct ui_call *call=&ui.calls[i];
        if(!*text(item,"state")||!j_get(item,"startedAt")) {ui.call_count=0;copy(ui.calls_error,sizeof ui.calls_error,"Invalid call history");return;}
        copy(call->number,sizeof call->number,text(item,"number"));copy(call->state,sizeof call->state,text(item,"state"));
        copy(call->direction,sizeof call->direction,text(item,"direction"));
        call->started_at=(uint64_t)j_int(j_get(item,"startedAt"));call->answered_at=(uint64_t)j_int(j_get(item,"answeredAt"));ui.call_count++;
    }
    ui.calls_valid=1;*ui.calls_error=0;
}
void ui_confirm_hotspot(void) {
    struct json_object *c=config();
    if(ui.page!=5||ui_busy()||!c||strcmp(text(c,"mode"),"repeater"))return;
    struct json_object *body=j_new();j_add(body,"mode",j_text("hotspot"));
    if(!ui_command("apply",body)) {ui.page=1;ui.busy=1;}
}
void ui_key(int character) {
    if(character<32||character>126)return;
    char *field=ui.field?ui.password:ui.ssid;size_t length=strlen(field),limit=ui.field?64:32;
    if(length<limit){field[length]=(char)character;field[length+1]=0;}
}
void ui_delete(void) {
    char *field=ui.field?ui.password:ui.ssid;size_t length=strlen(field);
    if(!length)return;
    /* SSIDs selected from a scan can contain UTF-8 even with an ASCII keyboard. */
    do {length--;} while(length&&((unsigned char)field[length]&0xc0)==0x80);
    ui_clear(field+length,strlen(field+length));
}
void ui_click(int x,int y) {
    if(!ui.page) { if(x>=258&&y>=180&&y<224)ui_open();return; }
    if(y<45&&x<65) {ui_back();return;}
    if(ui.page==5) {
        if(y>=288&&y<336) {
            if(x>=34&&x<154)ui_back();
            else if(x>=166&&x<286)ui_confirm_hotspot();
        }
    } else if(ui.page==1) {
        if(ui_busy()) return;
        if(y>=76&&y<124&&x>=190&&x<302) {ui_hotspot();return;}
        if(y>=108&&y<148) {
            ui_band(x<110?2:x<220?5:ui.band);return;
        }
        if(y>=158&&y<366) {
            int i=ui.offset+(y-158)/52;
            ui_select(i);
            return;
        }
        if(y>=374&&y<414) {if(x<160&&ui.offset>=4)ui.offset-=4;else if(x>=160&&ui.offset+4<ui.network_count)ui.offset+=4;return;}
        if(y>=428) {ui_other();return;}
    } else if(ui.page==2 || ui.page==3) {
        if(y>=104&&y<143&&ui.page==3) {ui.field=0;return;}
        if(y>=151&&y<190) {ui.field=1;return;}
        if(y>=204&&y<244) {ui_connect();return;}
        if(y>=270&&y<420) {
            int key=((y-270)/50)*10+x/32;const char *layout=ui_keys();
            if(key>=0&&(size_t)key<strlen(layout))ui_key(layout[key]);return;
        }
        if(y>=428) {
            if(x<75)ui.symbols=!ui.symbols;else if(x<150)ui.shift=!ui.shift;
            else if(x<240)ui_key(' ');else ui_delete();
        }
    }
}
static struct json_object *rpc(const char *request) {
    int fd=socket(AF_UNIX,SOCK_STREAM,0);if(fd<0)return NULL;
    if(fcntl(fd,F_SETFD,FD_CLOEXEC)<0){close(fd);return NULL;}
    struct timeval limit={.tv_sec=2};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&limit,sizeof limit);setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&limit,sizeof limit);
    struct sockaddr_un address={.sun_family=AF_UNIX};copy(address.sun_path,sizeof address.sun_path,UI_SOCKET);
    struct json_object *response=NULL;char *buffer=NULL;
    if(connect(fd,(struct sockaddr*)&address,sizeof address))goto done;
    for(size_t sent=0,length=strlen(request);sent<length;) {ssize_t n=send(fd,request+sent,length-sent,MSG_NOSIGNAL);if(n<=0)goto done;sent+=(size_t)n;}
    if(socket_shutdown(fd,SHUT_WR))goto done;buffer=malloc(UI_MAX+1);if(!buffer)goto done;
    size_t length=0;
    while(length<UI_MAX){ssize_t n=recv(fd,buffer+length,UI_MAX-length,0);if(!n)break;if(n<0)goto done;length+=(size_t)n;}
    if(length==UI_MAX)goto done;buffer[length]=0;response=j_parse(buffer);
 done:
    if(buffer){ui_clear(buffer,UI_MAX+1);free(buffer);}close(fd);return response;
}
static int counter(const char *iface,const char *metric,uint64_t *value) {
    char path[128];snprintf(path,sizeof path,"/sys/class/net/%s/statistics/%s_bytes",iface,metric);
    FILE *file=fopen(path,"r");if(!file)return -1;
    char extra;int valid=fscanf(file,"%" SCNu64 " %c",value,&extra)==1;fclose(file);return valid?0:-1;
}
void ui_hotspot_status(const char *response) {
    ui.hotspot_state=UI_HOTSPOT_UNKNOWN;*ui.hotspot_ssid=0;
    if(!response)return;
    int enabled=0;const char *ssid=NULL;size_t length=0;
    for(const char *line=response;*line;) {
        size_t n=strcspn(line,"\n");
        if(n==13&&!strncmp(line,"state=ENABLED",13))enabled=1;
        else if(n==14&&!strncmp(line,"state=DISABLED",14))enabled=-1;
        else if(n>=8&&!strncmp(line,"ssid[0]=",8)){ssid=line+8;length=n-8;}
        line+=n;if(*line)line++;
    }
    if(enabled<0){ui.hotspot_state=UI_HOTSPOT_DISABLED;return;}
    if(!enabled||!ssid||!length||length>32)return;
    for(size_t i=0;i<length;i++)if((unsigned char)ssid[i]<32||(unsigned char)ssid[i]==127)return;
    memcpy(ui.hotspot_ssid,ssid,length);ui.hotspot_ssid[length]=0;
    ui.hotspot_state=UI_HOTSPOT_ENABLED;
}
static int hotspot_status(int band,char *response,size_t capacity) {
    /* STATUS exposes the active broadcast name without loading wireless
     * configuration or keys. An abstract reply socket leaves no file behind. */
    int fd=socket(AF_UNIX,SOCK_DGRAM,0);if(fd<0)return -1;
    int result=-1;struct timeval limit={.tv_sec=1};
    if(fcntl(fd,F_SETFD,FD_CLOEXEC)<0||
       setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&limit,sizeof limit)||
       setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&limit,sizeof limit))goto done;
    struct sockaddr_un local={.sun_family=AF_UNIX},remote={.sun_family=AF_UNIX};
    int length=snprintf(local.sun_path+1,sizeof local.sun_path-1,"openu60-ui.ap.%ld",(long)getpid());
    if(length<0||(size_t)length>=sizeof local.sun_path-1)goto done;
    if(bind(fd,(struct sockaddr *)&local,(socklen_t)(offsetof(struct sockaddr_un,sun_path)+1+length)))goto done;
    snprintf(remote.sun_path,sizeof remote.sun_path,"/data/vendor/wifi/hostapd/%s",band==2?"wlan2":"wlan0");
    if(connect(fd,(struct sockaddr *)&remote,sizeof remote)||send(fd,"STATUS",6,0)!=6)goto done;
    ssize_t count=recv(fd,response,capacity-1,MSG_TRUNC);
    if(count<=0||(size_t)count>=capacity)goto done;
    response[count]=0;result=0;
 done:
    close(fd);return result;
}
void *ui_worker(void *unused) {
    (void)unused;uint64_t last_rx=0,last_tx=0;int last_band=0,last_valid=0;struct timespec previous={0};
    for(;;) {
        char command[8192]={0};pthread_mutex_lock(&ui.mutex);copy(command,sizeof command,ui.command);ui_clear(ui.command,sizeof ui.command);pthread_mutex_unlock(&ui.mutex);
        int had_command=*command!=0;
        if(had_command) {
            struct json_object *reply=rpc(command);ui_clear(command,sizeof command);
            pthread_mutex_lock(&ui.mutex);
            if(!reply) {ui.scan_pending_band=0;copy(ui.error,sizeof ui.error,"Local Wi-Fi service is unavailable.");}
            else {
                if(!j_bool(j_get(reply,"ok"))) {ui.scan_pending_band=0;copy(ui.error,sizeof ui.error,text(reply,"error"));}
                j_put(reply);
            }
            pthread_mutex_unlock(&ui.mutex);
        }
        struct json_object *reply=rpc("{\"action\":\"status\"}");
        pthread_mutex_lock(&ui.mutex);
        if(had_command) ui.in_flight=0;
        if(reply) ui_status(reply); else {ui.online=ui.connected=ui.busy=0;copy(ui.error,sizeof ui.error,"Local Wi-Fi service is unavailable.");}
        int connection_page=ui.page==4;
        struct json_object *c=config();int band=c&&!strcmp(text(c,"band"),"2g")?2:5;
        int repeater=c&&!strcmp(text(c,"mode"),"repeater")&&
            (!strcmp(text(c,"band"),"2g")||!strcmp(text(c,"band"),"5g"));
        int connected=ui.connected;pthread_mutex_unlock(&ui.mutex);
        if(connection_page) {
            struct json_object *connection=rpc("{\"action\":\"connection\"}");
            pthread_mutex_lock(&ui.mutex);
            if(connection && j_bool(j_get(connection,"ok"))) {
                struct json_object *data=j_get(connection,"data");
                copy(ui.connection_code,sizeof ui.connection_code,text(data,"connectionString"));
                copy(ui.connection_server,sizeof ui.connection_server,text(data,"serverURL"));
                *ui.connection_error=0;
            } else {
                *ui.connection_code=*ui.connection_server=0;
                copy(ui.connection_error,sizeof ui.connection_error,connection?text(connection,"error"):"Remote access is unavailable");
            }
            if(connection)j_put(connection);
            pthread_mutex_unlock(&ui.mutex);
        }
        struct json_object *calls=rpc("{\"action\":\"calls\"}");
        pthread_mutex_lock(&ui.mutex);ui_calls(calls);pthread_mutex_unlock(&ui.mutex);if(calls)j_put(calls);
        char hotspot[4096];int hotspot_ready=repeater&&!hotspot_status(band,hotspot,sizeof hotspot);
        pthread_mutex_lock(&ui.mutex);ui_hotspot_status(hotspot_ready?hotspot:NULL);pthread_mutex_unlock(&ui.mutex);
        uint64_t rx=0,tx=0;
        int valid=!counter(band==2?"wlan0":"wlan2","rx",&rx)&&!counter(band==2?"wlan0":"wlan2","tx",&tx);
        struct timespec now;clock_gettime(CLOCK_MONOTONIC,&now);
        double elapsed=now.tv_sec-previous.tv_sec+(now.tv_nsec-previous.tv_nsec)/1e9;
        pthread_mutex_lock(&ui.mutex);
        ui.rates_valid=connected&&valid&&last_valid&&last_band==band&&elapsed>0&&elapsed<5&&rx>=last_rx&&tx>=last_tx;
        if(ui.rates_valid){ui.rx_rate=(uint64_t)((rx-last_rx)/elapsed);ui.tx_rate=(uint64_t)((tx-last_tx)/elapsed);}
        pthread_mutex_unlock(&ui.mutex);last_rx=rx;last_tx=tx;last_band=band;previous=now;last_valid=valid;
        struct timespec delay={.tv_sec=1};nanosleep(&delay,NULL);
    }
    return NULL;
}
