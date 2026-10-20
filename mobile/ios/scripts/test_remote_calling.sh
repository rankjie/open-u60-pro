#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then
    echo "Usage: test_remote_calling.sh <booted-isolated-simulator-uuid>" >&2
    exit 2
fi
openu60_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
openu60_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
openu60_arch=$(uname -m)
openu60_framework="$openu60_root/target/ios-packages/artifacts/webrtc/WebRTC/WebRTC.xcframework/ios-x86_64_arm64-simulator"
if [ ! -d "$openu60_framework" ]; then
    echo "Resolve the pinned WebRTC package into target/ios-packages before running this check." >&2
    exit 1
fi
openu60_work=$(mktemp -d "${TMPDIR:-/tmp}/openu60-calling-tests.XXXXXX")
trap 'rm -rf "$openu60_work"' EXIT HUP INT TERM
xcrun --sdk iphonesimulator swiftc -swift-version 5 -parse-as-library -sdk "$openu60_sdk" \
    -target "$openu60_arch-apple-ios17.0-simulator" -F "$openu60_framework" \
    -Xlinker -rpath -Xlinker "$openu60_framework" -framework WebRTC \
    "$openu60_root/mobile/ios/OpenU60/Core/RemoteCalling/CallingCredentials.swift" \
    "$openu60_root/mobile/ios/OpenU60/Core/Networking/AgentTransport.swift" \
    "$openu60_root/mobile/ios/OpenU60/Core/Networking/AgentError.swift" \
    "$openu60_root/mobile/ios/OpenU60/Core/RemoteCalling/CallingMedia.swift" \
    "$openu60_root/mobile/ios/OpenU60/Core/RemoteCalling/RemoteCallingManager.swift" \
    "$openu60_root/mobile/ios/Tests/CallingTestDoubles.swift" \
    "$openu60_root/mobile/ios/Tests/RemoteCallingTests.swift" -o "$openu60_work/tests"
xcrun simctl spawn "$1" "$openu60_work/tests"
