#!/bin/sh
set -eu
openu60_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
openu60_runtime="$openu60_root/target/device-ui/runtime-root"
openu60_probe="$openu60_root/target/wifi-ui/abi-probe"
test "$(sha256sum "$openu60_runtime/usr/bin/zte_topsw_devui" | cut -d ' ' -f1)" = \
    7a158227890ddd5dc247ab1d198cef3cf69a13d2667892a980effc2a9f509ca0
test "$(sha256sum "$openu60_runtime/usr/lib/libzte_SDKowrt.so" | cut -d ' ' -f1)" = \
    7847ec604e7549c76da1b9e94326ce525ba7ea1fd51ee8e4422668d63f894fb7
mkdir -p "$openu60_probe"
zig cc -target aarch64-linux-musl -shared -fPIC -O1 -std=gnu11 -Wall -Wextra -Werror \
    "$openu60_root/native/wifi-ui/abi-probe.c" -ldl -o "$openu60_probe/probe.so"
# The runtime contains only public firmware ELF files and loader symlinks.
# No /data, configuration, credentials, display/input devices or network access.
docker run --rm --network none --read-only --security-opt no-new-privileges \
    --tmpfs /tmp -v "$openu60_runtime:/rt:ro" -v "$openu60_probe:/probe:ro" \
    alpine:3.20 timeout 5 /rt/lib/libc.so --library-path /rt/lib:/rt/usr/lib \
    --preload /probe/probe.so /rt/usr/bin/zte_topsw_devui
