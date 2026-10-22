#!/bin/sh
set -eu
openu60_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
mkdir -p "$openu60_root/target/wifi-ui"
zig cc -target aarch64-linux-musl -shared -fPIC -O2 -std=gnu11 -Wall -Wextra -Werror \
    $(pkg-config --cflags json-c) \
    "$openu60_root/native/wifi-ui/ui.c" "$openu60_root/native/wifi-ui/native_panel.c" \
    "$openu60_root/native/wifi-ui/native_hook.c" \
    "$openu60_root/native/wifi-ui/native_home.c" \
    "$openu60_root/native/wifi-ui/native_calls.c" \
    -Wl,-soname,libopenu60-native-ui.so -ldl -lpthread -o "$openu60_root/target/wifi-ui/libopenu60-native-ui.so"
