#!/bin/sh
set -eu
openu60_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
openu60_work=$(mktemp -d "${TMPDIR:-/tmp}/openu60-relay-paths-tests.XXXXXX")
trap 'rm -rf "$openu60_work"' EXIT HUP INT TERM
swiftc -swift-version 5 \
    "$openu60_root/mobile/ios/OpenU60/Core/RemoteCalling/RelayPaths.swift" \
    "$openu60_root/mobile/ios/Tests/RelayPathsTests.swift" -o "$openu60_work/tests"
"$openu60_work/tests"
