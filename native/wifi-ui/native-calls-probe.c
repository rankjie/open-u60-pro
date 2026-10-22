#define _GNU_SOURCE
#include "native_calls.c"
#include "native_home.h"
#include "font-fixture.h"
#include "lock-fixture.h"
#include <stdlib.h>
#include <unistd.h>
#include <dlfcn.h>
#define CHECK(x) do{if(!(x)){fprintf(stderr,"Call UI failure at line %d\n",__LINE__);return 1;}}while(0)
static uint16_t rendered[320*480];static int pressed,point_x,point_y;static int upgrade_clicks,help_clicks;
static void flush(void *driver,const void *area,uint16_t *pixels){int16_t b[4];memcpy(b,area,8);for(int y=b[1];y<=b[3];y++){memcpy(rendered+y*320+b[0],pixels,(b[2]-b[0]+1)*2);pixels+=b[2]-b[0]+1;}native_lvgl.flush_ready(driver);}
static void frames(void){for(unsigned i=0;i<35;i++){native_lvgl.timer_handler();usleep(2000);}}
static void pointer(void *driver,void *data){(void)driver;int16_t p[2]={319-point_x,479-point_y};memcpy(data,p,4);memcpy((char*)data+16,&pressed,4);}
static void tap(int x,int y){point_x=x;point_y=y;pressed=0;frames();pressed=1;frames();pressed=0;frames();}
static void original_clicked(native_event *event){int id=(int)(uintptr_t)native_lvgl.event_user_data(event);int32_t *route;memcpy(&route,(void*)0xe6fca8,8);*route=id;if(id==42)upgrade_clicks++;else help_clicks++;}
static native_obj *home_fixture(native_obj *factory){
    native_obj *body=native_lvgl.object_create(factory);native_surface(body,UI_BLACK,0);native_lvgl.set_position(body,0,24);native_lvgl.set_size(body,320,456);
    native_obj *content=native_lvgl.object_create(body);native_surface(content,UI_BLACK,0);native_lvgl.set_position(content,0,0);native_lvgl.set_size(content,320,432);
    native_obj *grid=NULL;
    for(unsigned i=0;i<20;i++){
        native_obj *item=i==16?native_lvgl.label_create(content):native_lvgl.object_create(content);
        if(i!=16){native_visible(item,0);continue;}grid=item;native_label_text(grid,"");native_lvgl.set_position(grid,0,0);native_lvgl.set_size(grid,320,432);
        native_obj *unused=native_lvgl.object_create(grid);native_visible(unused,0);
        for(unsigned j=1;j<=6;j++){
            native_obj *item=native_lvgl.menu_button_create(grid);native_lvgl.set_position(item,j%2?14:167,166+(j-1)/2*90);native_lvgl.set_size(item,139,80);native_surface(item,0x181818,16);native_lvgl.add_flag(item,2|EVENT_BUBBLE);
            label(item,0,0,1,1,"",NATIVE_MENU_FONT_20,0);label(item,0,0,1,1,"",NATIVE_MENU_FONT_20,0);
            label(item,13,10,125,32,j==5?"升级":j==6?"帮助":"网络",NATIVE_MENU_FONT_20,0);
            native_obj *icon=native_lvgl.image_create(item);native_lvgl.image_set_source(icon,NATIVE_MENU_CHEVRON);native_lvgl.set_position(icon,76,24);
            if(j>=5)native_lvgl.add_event(item,original_clicked,NATIVE_EVENT_CLICKED,(void*)(uintptr_t)(j==5?42:43));
        }
    }
    return grid;
}
static int output(const char *path){frames();FILE*f=fopen(path,"wb");if(!f)return -1;int ok=fwrite(rendered,sizeof rendered,1,f)==1&&!fclose(f);return ok?0:-1;}
static int probe_main(int argc,char **argv,char **env){
    (void)env;CHECK(argc==4&&ui_json_init()==0);native_lvgl.init();CHECK(!font_fixture());
    static _Alignas(16) unsigned char driver[0x98],buffer[0x28];static uint16_t pixels[320*480];
    native_lvgl.driver_init(driver);native_lvgl.buffer_init(buffer,pixels,NULL,320*480);void *buf=buffer;memcpy(driver+16,&buf,8);
    void(*draw)(void*,const void*,uint16_t*)=flush;memcpy(driver+32,&draw,8);uint32_t flags;memcpy(&flags,driver+24,4);flags=(flags&~0x30u)|0x20;memcpy(driver+24,&flags,4);
    native_display *display=native_lvgl.register_display(driver);CHECK(display);native_obj *screen=native_active_screen(display),*layers[4];
    for(unsigned i=0;i<4;i++){layers[i]=native_lvgl.object_create(screen);native_lvgl.set_position(layers[i],0,0);native_lvgl.set_size(layers[i],320,480);native_surface(layers[i],UI_BLACK,0);if(i)native_visible(layers[i],0);}
    native_obj *grid=home_fixture(layers[0]);CHECK(grid);int32_t *route;memcpy(&route,(void*)0xe6fca8,8);*route=0;frames();
    static _Alignas(8) unsigned char input[0x38];void(*init)(void*)=(void*)0x475170;void*(*register_input)(void*)=(void*)0x4751b4;
    init(input);uint32_t type=1;memcpy(input,&type,4);void(*read)(void*,void*)=pointer;memcpy(input+8,&read,8);memcpy(input+32,&display,8);CHECK(register_input(input));
    CHECK(!native_calls_refresh(display,1));frames();CHECK(call_tile&&help_tile&&upgrade_source&&help_source);
    CHECK(!strcmp(native_lvgl.label_get_text(child(upgrade_source,2)),"升级"));
    struct json_object *reply=j_parse("{\"ok\":true,\"data\":{\"items\":[{\"state\":\"ringing\",\"number\":\"+12025550123\",\"direction\":\"incoming\",\"startedAt\":1792666200},{\"state\":\"ended\",\"number\":\"+12025550124\",\"direction\":\"incoming\",\"startedAt\":1792666000},{\"state\":\"ended\",\"number\":\"+12025550125\",\"direction\":\"outgoing\",\"startedAt\":1792665000},{\"state\":\"ended\",\"startedAt\":1792664000},{\"state\":\"ended\",\"startedAt\":1792663000},{\"state\":\"ended\",\"startedAt\":1792662000}]}}");
    ui_calls(reply);j_put(reply);CHECK(ui.calls_valid&&ui.call_count==6);native_calls_refresh(display,1);CHECK(!native_is_hidden(banner));
    tap(83,410);CHECK(ui.page==CALLS&&upgrade_clicks==0);native_calls_refresh(display,1);CHECK(!native_is_hidden(history)&&native_is_hidden(banner));
    CHECK(strstr(native_lvgl.label_get_text(details[0]),"12:50"));CHECK(!output(argv[1]));
    tap(230,445);native_calls_refresh(display,1);CHECK(offset==5);tap(85,445);native_calls_refresh(display,1);CHECK(offset==0);
    tap(30,45);CHECK(ui.page==0);native_calls_refresh(display,1);tap(236,410);CHECK(ui.page==HELP&&help_clicks==0);native_calls_refresh(display,1);CHECK(!output(argv[2]));
    tap(160,174);CHECK(upgrade_clicks==1&&*route==42&&ui.page==0);*route=0;native_calls_refresh(display,1);
    tap(236,410);native_calls_refresh(display,1);tap(160,113);CHECK(help_clicks==1&&*route==43);*route=0;native_calls_refresh(display,1);
    tap(83,410);native_calls_refresh(display,0);CHECK(ui.page==0&&native_is_hidden(history));
    native_obj *lock=lock_fixture(layers[2]);CHECK(lock);native_visible(layers[2],1);native_calls_refresh(display,0);CHECK(!native_is_hidden(banner));
    uint32_t banner_flags;memcpy(&banner_flags,(char*)banner+48,4);CHECK(!(banner_flags&2));
    native_visible(layers[2],0);ui.page=0;native_lvgl.set_position(grid,320,0);
    ui_status(j_parse("{\"ok\":true,\"data\":{\"config\":{\"mode\":\"repeater\",\"ssid\":\"Home\",\"band\":\"5g\"},\"phase\":\"connected\",\"connectivity\":\"online\",\"ipv4\":\"192.0.2.2\",\"networks\":[]}}"));
    ui.rates_valid=1;ui.rx_rate=10471250;ui.tx_rate=525000;ui_hotspot_status("state=ENABLED\nssid[0]=Travel Wi-Fi\n");frames();CHECK(!native_home_refresh(display,1));native_calls_refresh(display,1);CHECK(!output(argv[3]));
    ui_calls(NULL);native_calls_refresh(display,1);CHECK(native_is_hidden(banner));
    native_obj *top;memcpy(&top,(char*)display+0x38,8);native_lvgl.object_clean(top);CHECK(!native_calls_refresh(display,1));CHECK(history&&help&&banner);
    puts("Native calls: real touch routing, original updater/help, call history, lock status and owned-root recovery passed");return 0;
}
int __libc_start_main(int(*main_fn)(int,char**,char**),int argc,char**argv,void(*init_fn)(void),void(*fini_fn)(void),void(*ldso_fn)(void)){
    (void)main_fn;
    int(*real)(int(*)(int,char**,char**),int,char**,void(*)(void),void(*)(void),void(*)(void));
    *(void**)&real=dlsym(RTLD_NEXT,"__libc_start_main");if(!real)_Exit(125);
    return real(probe_main,argc,argv,init_fn,fini_fn,ldso_fn);
}
