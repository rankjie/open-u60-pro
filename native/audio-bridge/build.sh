#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p ../../target/audio-bridge
zig cc -target aarch64-linux-musl -std=c11 -O2 -Wall -Wextra -Werror -shared -fPIC -pthread \
  bridge.c -o ../../target/audio-bridge/libopenu60-audio.so
