#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then echo "Usage: test_sms_cache.sh <booted-isolated-simulator-uuid>" >&2; exit 2; fi
openu60_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
openu60_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
openu60_work=$(mktemp -d "${TMPDIR:-/tmp}/openu60-sms-cache-tests.XXXXXX")
trap 'rm -rf "$openu60_work"' EXIT HUP INT TERM
xcrun --sdk iphonesimulator swiftc -swift-version 5 -parse-as-library -sdk "$openu60_sdk" \
    -target "$(uname -m)-apple-ios17.0-simulator" \
    "$openu60_root/mobile/ios/OpenU60/Core/Networking/AgentError.swift" \
    "$openu60_root/mobile/ios/OpenU60/Core/Networking/DeviceSnapshotCache.swift" \
    "$openu60_root/mobile/ios/OpenU60/Core/Models/IdentifiedList.swift" \
    "$openu60_root/mobile/ios/OpenU60/Core/Models/CellularLine.swift" \
    "$openu60_root/mobile/ios/OpenU60/Features/SMS/SMSModels.swift" \
    "$openu60_root/mobile/ios/OpenU60/Features/SMS/SMSDelivery.swift" \
    "$openu60_root/mobile/ios/OpenU60/Features/SMS/SMSViewModel.swift" \
    "$openu60_root/mobile/ios/Tests/SMSCacheTests.swift" -o "$openu60_work/tests"
xcrun simctl spawn "$1" "$openu60_work/tests"
