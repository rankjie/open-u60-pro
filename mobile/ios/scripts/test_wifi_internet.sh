#!/bin/sh
set -eu
openu60_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
openu60_work=$(mktemp -d "${TMPDIR:-/tmp}/openu60-wifi-tests.XXXXXX")
trap 'rm -rf "$openu60_work"' EXIT HUP INT TERM
swiftc -swift-version 5 -parse-as-library \
    "$openu60_root/mobile/ios/OpenU60/Core/Networking/AgentError.swift" \
    "$openu60_root/mobile/ios/OpenU60/Features/RouterSettings/WiFi/WiFiInternetViewModel.swift" \
    "$openu60_root/mobile/ios/Tests/WiFiInternetTests.swift" -o "$openu60_work/tests"
"$openu60_work/tests"
