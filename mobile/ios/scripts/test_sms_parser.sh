#!/bin/sh
set -eu
openu60_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
openu60_work=$(mktemp -d "${TMPDIR:-/tmp}/openu60-sms-tests.XXXXXX")
trap 'rm -rf "$openu60_work"' EXIT HUP INT TERM
swiftc -swift-version 5 \
    "$openu60_root/mobile/ios/OpenU60/Core/Models/CellularLine.swift" \
    "$openu60_root/mobile/ios/OpenU60/Features/SMS/SMSModels.swift" \
    "$openu60_root/mobile/ios/OpenU60/Features/SMS/SMSDelivery.swift" \
    "$openu60_root/mobile/ios/Tests/SMSParserTests.swift" -o "$openu60_work/tests"
"$openu60_work/tests"
