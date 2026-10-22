#include "native_calls.h"
#include "native_layout.h"
#include "native_theme.h"
#include "native_render.h"
#include "ui.h"
#include <stdio.h>
#include <string.h>
#include <time.h>

enum {CALLS=6,HELP=7,EVENT_BUBBLE=1u<<14,GESTURE_BUBBLE=1u<<15};
enum action {OPEN_CALLS,OPEN_HELP,BACK_CALLS,UPGRADE,FACTORY_HELP,PREVIOUS_CALLS,NEXT_CALLS};
static native_obj *history,*help,*banner,*banner_title,*banner_number,*empty;
static native_obj *titles[5],*details[5],*rows[5],*previous,*next;
static native_obj *grid_owner,*upgrade_source,*help_source,*call_tile,*help_tile;
static int needs_rebuild,offset;
static native_obj *child(native_obj *object,unsigned index) {
    if(!object)return NULL;void *attributes;uint32_t count;native_obj **children,*result;
    memcpy(&attributes,(char*)object+0x10,8);if(!attributes)return NULL;
    memcpy(&count,(char*)attributes+8,4);if(count>32||index>=count)return NULL;
    memcpy(&children,attributes,8);if(!children)return NULL;memcpy(&result,children+index,8);return result;
}
static unsigned count(native_obj *object) {
    void *attributes;uint32_t value;memcpy(&attributes,(char*)object+0x10,8);if(!attributes)return 0;
    memcpy(&value,(char*)attributes+8,4);return value;
}
static int klass(native_obj *object,uintptr_t expected) {uintptr_t value=0;if(object)memcpy(&value,object,8);return value==expected;}
static native_obj *label(native_obj *parent,int x,int y,int w,int h,const char *value,uintptr_t font,int center) {
    native_obj *object=native_lvgl.label_create(parent);if(!object)return NULL;
    native_lvgl.set_position(object,x,y);native_lvgl.set_size(object,w,h);
    native_type(object,font,0xe7e7e7,center);native_label_text(object,value);return object;
}
static void deleted(native_event *event) {
    native_obj *target=native_lvgl.event_target(event);
    if(target==call_tile){call_tile=NULL;grid_owner=upgrade_source=help_source=NULL;}
    if(target==help_tile){help_tile=NULL;grid_owner=upgrade_source=help_source=NULL;}
    if(target==history){history=NULL;needs_rebuild=1;}
    if(target==help){help=NULL;needs_rebuild=1;}
    if(target==banner){banner=NULL;needs_rebuild=1;}
}
static void clicked(native_event *event) {
    enum action action=(enum action)(uintptr_t)native_lvgl.event_user_data(event);
    pthread_mutex_lock(&ui.mutex);
    if(action==OPEN_CALLS){ui.page=CALLS;offset=0;}
    else if(action==OPEN_HELP)ui.page=HELP;
    else if(action==BACK_CALLS)ui.page=0;
    else if(action==PREVIOUS_CALLS&&offset>=5)offset-=5;
    else if(action==NEXT_CALLS&&offset+5<ui.call_count)offset+=5;
    else if(action==UPGRADE||action==FACTORY_HELP)ui.page=0;
    pthread_mutex_unlock(&ui.mutex);
    /* Dispatch the original untouched factory control. A child overlay handles
     * the new menu slot; no original callback or firmware bytes are replaced. */
    if(action==UPGRADE&&upgrade_source)native_lvgl.send_event(upgrade_source,NATIVE_EVENT_CLICKED,NULL);
    if(action==FACTORY_HELP&&help_source)native_lvgl.send_event(help_source,NATIVE_EVENT_CLICKED,NULL);
}
static native_obj *button(native_obj *parent,int x,int y,int w,int h,const char *title,enum action action) {
    native_obj *object=native_lvgl.menu_button_create(parent);if(!object)return NULL;
    native_lvgl.set_position(object,x,y);native_lvgl.set_size(object,w,h);native_surface(object,0x181818,16);
    native_lvgl.set_style(object,NATIVE_STYLE_BG_COLOR,native_rgb(UI_LINE),0x20);
    native_lvgl.add_flag(object,2);native_lvgl.clear_flag(object,EVENT_BUBBLE);
    if(!label(object,8,(h-24)/2,w-16,24,title,NATIVE_MENU_FONT_20,1)||
       !native_lvgl.add_event(object,clicked,NATIVE_EVENT_CLICKED,(void*)(uintptr_t)action))return NULL;
    return object;
}
static native_obj *page(native_obj *top,const char *title) {
    native_obj *root=native_lvgl.object_create(top);if(!root)return NULL;
    native_lvgl.set_position(root,0,24);native_lvgl.set_size(root,320,456);native_surface(root,UI_BLACK,0);native_lvgl.add_flag(root,2);
    native_obj *back=button(root,0,0,64,42,"‹",BACK_CALLS);
    if(!back||!label(root,64,8,192,32,title,NATIVE_MENU_FONT_20,1))return NULL;
    native_surface(back,UI_BLACK,0);
    if(!native_lvgl.add_event(root,deleted,NATIVE_EVENT_DELETE,NULL))return NULL;
    native_visible(root,0);return root;
}
static int create(native_obj *top) {
    history=page(top,"通话记录");help=page(top,"帮助");banner=native_lvgl.object_create(top);
    if(!history||!help||!banner)return -1;
    native_lvgl.set_position(banner,18,56);native_lvgl.set_size(banner,284,64);native_surface(banner,0x181818,16);
    native_lvgl.clear_flag(banner,2);native_lvgl.add_event(banner,deleted,NATIVE_EVENT_DELETE,NULL);
    banner_title=label(banner,10,6,264,24,"",NATIVE_MENU_FONT_20,1);
    banner_number=label(banner,10,34,264,24,"",NATIVE_MENU_FONT_20,1);
    for(int i=0;i<5;i++) {
        rows[i]=native_lvgl.object_create(history);if(!rows[i])return -1;
        native_lvgl.set_position(rows[i],18,60+i*64);native_lvgl.set_size(rows[i],284,60);native_surface(rows[i],0x181818,16);
        titles[i]=label(rows[i],12,6,260,26,"",NATIVE_MENU_FONT_20,0);
        details[i]=label(rows[i],12,34,260,22,"",NATIVE_MENU_FONT_16,0);
        if(!titles[i]||!details[i])return -1;native_type(details[i],NATIVE_MENU_FONT_16,0x949a9c,0);
    }
    empty=label(history,18,160,284,100,"暂无通话记录",NATIVE_MENU_FONT_20,1);
    previous=button(history,18,400,136,44,"上一页",PREVIOUS_CALLS);next=button(history,166,400,136,44,"下一页",NEXT_CALLS);
    if(!banner_title||!banner_number||!empty||!previous||!next||!button(help,18,64,284,52,"使用帮助",FACTORY_HELP)||
       !button(help,18,124,284,52,"固件升级",UPGRADE))return -1;
    native_visible(banner,0);needs_rebuild=0;return 0;
}
static native_obj *tile(native_obj *source,const char *title,enum action action,int phone) {
    native_obj *object=native_lvgl.menu_button_create(source);if(!object)return NULL;
    native_lvgl.set_position(object,0,0);native_lvgl.set_size(object,139,80);
    native_surface(object,0x181818,16);native_lvgl.add_flag(object,2|GESTURE_BUBBLE);native_lvgl.clear_flag(object,EVENT_BUBBLE);
    native_lvgl.set_style(object,NATIVE_STYLE_BG_COLOR,native_rgb(UI_LINE),0x20);
    native_obj *caption=label(object,13,10,125,32,title,NATIVE_MENU_FONT_20,0);if(!caption)return NULL;
    native_lvgl.set_style(caption,NATIVE_STYLE_TEXT_FONT,native_lvgl.get_style(child(source,2),0,NATIVE_STYLE_TEXT_FONT),0);
    if(phone) {
        if(!label(object,76,26,48,48,"\xef\x82\x95",NATIVE_FONT_40,1))return NULL;
    } else {
        native_obj *image=native_lvgl.image_create(object);if(!image)return NULL;
        const void *art;memcpy(&art,(char*)child(source,3)+0x38,sizeof art);
        native_lvgl.image_set_source(image,art);native_lvgl.set_position(image,76,24);
    }
    if(!native_lvgl.add_event(object,clicked,NATIVE_EVENT_CLICKED,(void*)(uintptr_t)action)||!native_lvgl.add_event(object,deleted,NATIVE_EVENT_DELETE,NULL))return NULL;
    return object;
}
static int bind_tiles(native_display *display) {
    native_obj *factory=child(native_active_screen(display),0),*body=NULL;
    for(unsigned i=0;factory&&i<16;i++) {
        native_obj *candidate=child(factory,i);if(!candidate)break;if(native_is_hidden(candidate))continue;
        int16_t b[4];memcpy(b,(char*)candidate+0x28,sizeof b);
        if(b[0]==0&&b[1]==24&&b[2]==319&&b[3]==479){body=candidate;break;}
    }
    native_obj *content=child(body,0);if(!content||(count(content)!=20&&count(content)!=21))return 1;
    native_obj *grid=child(content,16);if(!klass(grid,0xe60398)||count(grid)!=7)return 1;
    if(grid==grid_owner)return 0;
    native_obj *upgrade=child(grid,5),*factory_help=child(grid,6);
    if(!klass(upgrade,0xe60248)||!klass(factory_help,0xe60248)||!klass(child(upgrade,2),0xe60398)||!klass(child(factory_help,2),0xe60398)||
       !klass(child(upgrade,3),0xe60368)||!klass(child(factory_help,3),0xe60368)||
       strcmp(native_lvgl.label_get_text(child(upgrade,2)),"升级")||strcmp(native_lvgl.label_get_text(child(factory_help,2)),"帮助"))return 1;
    if(call_tile)native_lvgl.object_delete(call_tile);if(help_tile)native_lvgl.object_delete(help_tile);
    upgrade_source=upgrade;help_source=factory_help;
    call_tile=tile(upgrade,"通话",OPEN_CALLS,1);help_tile=tile(factory_help,"帮助",OPEN_HELP,0);
    if(!call_tile||!help_tile)return -1;grid_owner=grid;return 0;
}
static const char *state(const struct ui_call *call) {
    if(!strcmp(call->state,"ringing"))return "来电";
    if(!strcmp(call->state,"active"))return "通话中";
    if(!strcmp(call->state,"answering"))return "正在接听";
    if(!strcmp(call->state,"dialing"))return "正在拨号";
    if(!call->answered_at)return !strcmp(call->direction,"incoming")?"未接来电":"未接通";
    return !strcmp(call->direction,"incoming")?"已接来电":"已拨电话";
}
int native_calls_refresh(native_display *display,int unlocked) {
    if(needs_rebuild) {
        if(history)native_lvgl.object_delete(history);if(help)native_lvgl.object_delete(help);if(banner)native_lvgl.object_delete(banner);
        pthread_mutex_lock(&ui.mutex);if(ui.page==CALLS||ui.page==HELP)ui.page=0;pthread_mutex_unlock(&ui.mutex);
    }
    if(!history) {
        native_obj *top;memcpy(&top,(char*)display+0x38,sizeof top);if(!top||create(top))return -1;
    }
    int result=unlocked&&native_current_form()==0?bind_tiles(display):0;
    pthread_mutex_lock(&ui.mutex);
    native_visible(history,unlocked&&ui.page==CALLS);native_visible(help,unlocked&&ui.page==HELP);
    if(!unlocked&&(ui.page==CALLS||ui.page==HELP))ui.page=0;
    const struct ui_call *active=NULL;
    if(ui.calls_valid)for(int i=0;i<ui.call_count;i++)if(strcmp(ui.calls[i].state,"ended")){active=&ui.calls[i];break;}
    native_obj *screen=native_active_screen(display),*modal=child(screen,3),*lock=child(screen,2);
    native_obj *lock_body=child(lock,1),*pin=child(lock,0);
    int locked_view=!unlocked&&lock&&!native_is_hidden(lock)&&lock_body&&!native_is_hidden(lock_body)&&pin&&native_is_hidden(pin);
    int show=active&&!ui.page&&(locked_view||(unlocked&&native_current_form()==0))&&modal&&native_is_hidden(modal);
    native_visible(banner,show);
    if(show){native_label_text(banner_title,state(active));native_label_text(banner_number,*active->number?active->number:"未知号码");}
    if(unlocked&&ui.page==CALLS) {
        if(offset>=ui.call_count)offset=0;
        native_visible(empty,!ui.calls_valid||!ui.call_count);
        native_label_text(empty,!ui.calls_valid?"通话记录暂不可用":"暂无通话记录");
        for(int i=0;i<5;i++) {
            int index=offset+i;native_visible(rows[i],ui.calls_valid&&index<ui.call_count);
            if(!ui.calls_valid||index>=ui.call_count)continue;
            const struct ui_call *call=&ui.calls[index];native_label_text(titles[i],*call->number?call->number:"未知号码");
            time_t at=(time_t)call->started_at;struct tm local;char date[32],detail[96];
            if(localtime_r(&at,&local))strftime(date,sizeof date,"%m-%d %H:%M",&local);else snprintf(date,sizeof date,"时间不可用");
            snprintf(detail,sizeof detail,"%s · %s",state(call),date);native_label_text(details[i],detail);
        }
        native_visible(previous,offset>=5);native_visible(next,offset+5<ui.call_count);
    }
    pthread_mutex_unlock(&ui.mutex);return result;
}
