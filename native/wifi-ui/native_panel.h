#ifndef OPENU60_NATIVE_PANEL_H
#define OPENU60_NATIVE_PANEL_H
#include "lvgl_abi.h"
int native_panel_create(native_obj *top);
/* Zero is ready, one waits for factory menu construction, negative is failure. */
int native_panel_refresh(int unlocked);
#endif
