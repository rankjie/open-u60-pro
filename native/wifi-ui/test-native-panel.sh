#!/bin/sh
set -eu
openu60_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
openu60_runtime="$openu60_root/target/device-ui/runtime-root"
openu60_probe="$openu60_root/target/wifi-ui/native-panel-probe"
test "$(sha256sum "$openu60_runtime/usr/bin/zte_topsw_devui" | cut -d ' ' -f1)" = \
    7a158227890ddd5dc247ab1d198cef3cf69a13d2667892a980effc2a9f509ca0
mkdir -p "$openu60_probe"
test "$(sha256sum "$openu60_runtime/usr/ui/fonts/ZTEZhengYuan.ttf" | cut -d ' ' -f1)" = \
    b8b1aca17b0e53c2ea7e840f7fe5d6f05db038f2d549fde95c1308a600665a56
test "$(sha256sum "$openu60_runtime/usr/ui/fonts/Zoswald-Medium-24.ttf" | cut -d ' ' -f1)" = \
    fb09900a394215cc83111b8ec2df7ad1a504e6123450cf62c5c260d04bb7cb8e
zig cc -target aarch64-linux-musl -shared -fPIC -O1 -std=gnu11 -Wall -Wextra -Werror \
    $(pkg-config --cflags json-c) \
    "$openu60_root/native/wifi-ui/native-panel-probe.c" "$openu60_root/native/wifi-ui/ui.c" \
    "$openu60_root/native/wifi-ui/native_home.c" \
    -ldl -lpthread -o "$openu60_probe/probe.so"
docker run --rm --network none --read-only --security-opt no-new-privileges \
    --tmpfs /tmp -v "$openu60_runtime:/rt:ro" -v "$openu60_probe:/probe:ro" \
    -v "$openu60_runtime/usr/ui/fonts:/usr/ui/fonts:ro" \
    -v "$openu60_probe:/out" \
    alpine:3.20 timeout 8 /rt/lib/libc.so --library-path /rt/lib:/rt/usr/lib \
    --preload /probe/probe.so /rt/usr/bin/zte_topsw_devui /out/panel.rgb565 /out/connection.rgb565 /out/keyboard.rgb565 /out/home.rgb565 /out/menu.rgb565 /out/lock.rgb565 /out/confirmation.rgb565 \
    > "$openu60_probe/run.log" 2>&1 || {
        cat "$openu60_probe/run.log"
        exit 1
    }
cat "$openu60_probe/run.log"
grep -Fxq 'Native Wi-Fi: real LVGL click routing, scan/grouping, join, masked input, keyboard coverage, apply, lock and rendering passed' "$openu60_probe/run.log"
