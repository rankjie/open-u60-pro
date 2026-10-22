#!/bin/sh
set -eu
openu60_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
mkdir -p "$openu60_root/target/wifi-ui"
zig cc -target aarch64-linux-musl -static -O2 -std=gnu11 -Wall -Wextra -Werror \
    "$openu60_root/native/wifi-ui/recovery.c" \
    -o "$openu60_root/target/wifi-ui/openu60-ui-recovery"
