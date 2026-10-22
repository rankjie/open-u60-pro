#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then
    echo 'Usage: test_native_media.sh <booted-isolated-simulator-uuid>' >&2
    exit 2
fi
openu60_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
openu60_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
openu60_arch=$(uname -m)
openu60_framework="$openu60_root/target/ios-packages/artifacts/webrtc/WebRTC/WebRTC.xcframework/ios-x86_64_arm64-simulator"
openu60_work=$(mktemp -d "${TMPDIR:-/tmp}/openu60-native-media.XXXXXX")
openu60_pid=''
cleanup() {
    if [ -n "$openu60_pid" ]; then
        kill "$openu60_pid" 2>/dev/null || true
        wait "$openu60_pid" 2>/dev/null || true
    fi
    rm -rf "$openu60_work"
}
trap cleanup EXIT HUP INT TERM
cd "$openu60_root"
cargo build --locked -p zte-agent --example native_media_gateway
xcrun --sdk iphonesimulator swiftc -swift-version 5 -parse-as-library -sdk "$openu60_sdk" \
    -target "$openu60_arch-apple-ios17.0-simulator" -F "$openu60_framework" \
    -Xlinker -rpath -Xlinker "$openu60_framework" -framework WebRTC \
    mobile/ios/OpenU60/Core/RemoteCalling/CallingCredentials.swift \
    mobile/ios/OpenU60/Core/RemoteCalling/RelayPaths.swift \
    mobile/ios/OpenU60/Core/RemoteCalling/CallingMedia.swift \
    mobile/ios/Tests/NativeMediaInteropTests.swift -o "$openu60_work/tests"
target/debug/examples/native_media_gateway > "$openu60_work/gateway.log" 2>&1 &
openu60_pid=$!
openu60_attempt=0
until rg -q '^Native media fixture listening on loopback$' "$openu60_work/gateway.log"; do
    if ! kill -0 "$openu60_pid" 2>/dev/null || [ "$openu60_attempt" -ge 50 ]; then
        cat "$openu60_work/gateway.log" >&2
        exit 1
    fi
    sleep 0.1
    openu60_attempt=$((openu60_attempt + 1))
done
xcrun simctl spawn "$1" "$openu60_work/tests"
wait "$openu60_pid"
openu60_pid=''
cat "$openu60_work/gateway.log"
