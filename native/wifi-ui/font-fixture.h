#ifndef OPENU60_FONT_FIXTURE_H
#define OPENU60_FONT_FIXTURE_H
#include "lvgl_abi.h"
#include <string.h>

/* Only isolated renderer tests load a public firmware font. Production uses
 * the already initialized factory descriptors without replacing their data. */
static int font_fixture(void) {
    int (*init)(uint16_t, uint16_t, uint32_t) = (void *)0x448998;
    void *(*manager)(void) = (void *)0x557ee4;
    void (*select_family)(void *, unsigned) = (void *)0x55840c;
    if (!init(0,0,0)) return -1;
    select_family(manager(),2);
    return NATIVE_MENU_FONT_16 && NATIVE_MENU_FONT_20 ? 0 : -1;
}
#endif
