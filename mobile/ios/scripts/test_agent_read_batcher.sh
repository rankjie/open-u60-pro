#!/bin/sh
set -eu
openu60_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
openu60_work=$(mktemp -d "${TMPDIR:-/tmp}/openu60-batcher-tests.XXXXXX")
trap 'rm -rf "$openu60_work"' EXIT HUP INT TERM
swiftc -swift-version 5 \
    "$openu60_root/mobile/ios/OpenU60/Core/Networking/AgentError.swift" \
    "$openu60_root/mobile/ios/OpenU60/Core/Networking/AgentTransport.swift" \
    "$openu60_root/mobile/ios/OpenU60/Core/Networking/AgentReadBatcher.swift" \
    "$openu60_root/mobile/ios/Tests/AgentReadBatcherTests.swift" -o "$openu60_work/tests"
"$openu60_work/tests"
