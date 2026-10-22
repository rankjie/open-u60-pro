#ifndef OPENU60_NATIVE_HEALTH_H
#define OPENU60_NATIVE_HEALTH_H
#include <stddef.h>

#define NATIVE_FAULT_PATH "/tmp/openu60-native-ui.fault"
enum native_fault {
    NATIVE_FAULT_SYMBOLS = 1,
    NATIVE_FAULT_JSON,
    NATIVE_FAULT_PANEL,
    NATIVE_FAULT_WORKER,
    NATIVE_FAULT_HOME,
    NATIVE_FAULT_HOME_LAYOUT,
    NATIVE_FAULT_HEALTH,
    NATIVE_FAULT_CLOCK,
};
static inline const char *native_fault_reason(unsigned code) {
    switch (code) {
    case NATIVE_FAULT_SYMBOLS: return "native SDK symbols unavailable";
    case NATIVE_FAULT_JSON: return "native JSON ABI unavailable";
    case NATIVE_FAULT_PANEL: return "native panel creation failed";
    case NATIVE_FAULT_WORKER: return "native status worker failed";
    case NATIVE_FAULT_HOME: return "native Home binding failed";
    case NATIVE_FAULT_HOME_LAYOUT: return "native Home layout deadline reached";
    case NATIVE_FAULT_HEALTH: return "native health publication failed";
    case NATIVE_FAULT_CLOCK: return "native monotonic clock failed";
    default: return NULL;
    }
}
#endif
