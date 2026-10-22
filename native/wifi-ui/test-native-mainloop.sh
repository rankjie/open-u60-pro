#!/bin/sh
set -eu
openu60_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
openu60_runtime="$openu60_root/target/device-ui/runtime-root"
openu60_probe="$openu60_root/target/wifi-ui/main-loop-probe"
test "$(sha256sum "$openu60_runtime/usr/bin/zte_topsw_devui" | cut -d ' ' -f1)" = \
    7a158227890ddd5dc247ab1d198cef3cf69a13d2667892a980effc2a9f509ca0
test "$(sha256sum "$openu60_runtime/usr/lib/libzte_SDKowrt.so" | cut -d ' ' -f1)" = \
    7847ec604e7549c76da1b9e94326ce525ba7ea1fd51ee8e4422668d63f894fb7
mkdir -p "$openu60_probe"
test "$(sha256sum "$openu60_runtime/usr/ui/fonts/ZTEZhengYuan.ttf" | cut -d ' ' -f1)" = \
    b8b1aca17b0e53c2ea7e840f7fe5d6f05db038f2d549fde95c1308a600665a56
test "$(sha256sum "$openu60_runtime/usr/ui/fonts/Zoswald-Medium-24.ttf" | cut -d ' ' -f1)" = \
    fb09900a394215cc83111b8ec2df7ad1a504e6123450cf62c5c260d04bb7cb8e
zig cc -target aarch64-linux-musl -shared -fPIC -O2 -std=gnu11 -Wall -Wextra -Werror \
    $(pkg-config --cflags json-c) '-DUI_SOCKET="/tmp/openu60-wifi-probe.sock"' \
    "$openu60_root/native/wifi-ui/main-loop-probe.c" "$openu60_root/native/wifi-ui/ui.c" \
    "$openu60_root/native/wifi-ui/native_home.c" "$openu60_root/native/wifi-ui/native_calls.c" \
    -ldl -lpthread -o "$openu60_probe/probe.so"
docker run --rm --network none --read-only --security-opt no-new-privileges \
    --tmpfs /tmp -v "$openu60_runtime:/rt:ro" -v "$openu60_probe:/probe:ro" \
    -v "$openu60_runtime/usr/ui/fonts:/usr/ui/fonts:ro" \
    alpine:3.20 timeout 8 /rt/lib/libc.so --library-path /rt/lib:/rt/usr/lib \
    --preload /probe/probe.so /rt/usr/bin/zte_topsw_devui > "$openu60_probe/run.log" 2>&1 || {
        cat "$openu60_probe/run.log"
        exit 1
    }
cat "$openu60_probe/run.log"
# The factory main can exit zero when hardware is absent; only the probe's
# completed behavior checks establish a successful isolated integration run.
grep -Fxq 'Native integration: original main loop, real worker RPC, pending scan ownership, UI heartbeat, stock lock/unlock and rate ABI passed' "$openu60_probe/run.log"
