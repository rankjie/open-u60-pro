#ifndef OPENU60_NATIVE_HOME_H
#define OPENU60_NATIVE_HOME_H
#include "lvgl_abi.h"
/* Refresh repeater information on Home and the stock lock. UI thread only.
 * 0: applied/hidden, 1: factory layout pending, -1: failed. */
int native_home_refresh(native_display *display, int unlocked);
int native_home_visible(void);
#endif
