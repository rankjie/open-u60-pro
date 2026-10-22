#!/bin/sh
set -eu
openu60_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
openu60_runtime="$openu60_root/target/device-ui/runtime-root"
openu60_probe="$openu60_root/target/wifi-ui/native-calls-probe"
test "$(sha256sum "$openu60_runtime/usr/bin/zte_topsw_devui" | cut -d ' ' -f1)" = 7a158227890ddd5dc247ab1d198cef3cf69a13d2667892a980effc2a9f509ca0
mkdir -p "$openu60_probe"
zig cc -target aarch64-linux-musl -shared -fPIC -O1 -std=gnu11 -Wall -Wextra -Werror \
    $(pkg-config --cflags json-c) "$openu60_root/native/wifi-ui/native-calls-probe.c" \
    "$openu60_root/native/wifi-ui/ui.c" "$openu60_root/native/wifi-ui/native_home.c" \
    -ldl -lpthread -o "$openu60_probe/probe.so"
docker run --rm --network none --read-only --security-opt no-new-privileges --tmpfs /tmp \
    -e 'TZ=CET-1CEST,M3.5.0,M10.5.0/3' \
    -v "$openu60_runtime:/rt:ro" -v "$openu60_probe:/probe:ro" -v "$openu60_probe:/out" \
    -v "$openu60_runtime/usr/ui/fonts:/usr/ui/fonts:ro" alpine:3.20 timeout 8 \
    /rt/lib/libc.so --library-path /rt/lib:/rt/usr/lib --preload /probe/probe.so \
    /rt/usr/bin/zte_topsw_devui /out/calls.rgb565 /out/help.rgb565 /out/call-home.rgb565 \
    > "$openu60_probe/run.log" 2>&1 || { cat "$openu60_probe/run.log"; exit 1; }
cat "$openu60_probe/run.log"
grep -Fxq 'Native calls: real touch routing, original updater/help, call history, lock status and owned-root recovery passed' "$openu60_probe/run.log"
