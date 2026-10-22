#!/bin/sh
set -eu
openu60_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
openu60_work=$(mktemp -d "${TMPDIR:-/tmp}/openu60-sim-state-tests.XXXXXX")
trap 'rm -rf "$openu60_work"' EXIT HUP INT TERM
swiftc -swift-version 5 -parse-as-library \
    "$openu60_root/mobile/ios/OpenU60/Core/Networking/AgentError.swift" \
    "$openu60_root/mobile/ios/OpenU60/Core/Networking/AgentTransport.swift" \
    "$openu60_root/mobile/ios/OpenU60/Core/Networking/PeerFrames.swift" \
    "$openu60_root/mobile/ios/OpenU60/Core/Networking/AgentClient.swift" \
    "$openu60_root/mobile/ios/OpenU60/Core/Networking/AgentReadPool.swift" \
    "$openu60_root/mobile/ios/OpenU60/Core/Models/SimIdentity.swift" \
    "$openu60_root/mobile/ios/OpenU60/Core/Models/CellularLine.swift" \
    "$openu60_root/mobile/ios/OpenU60/Core/Models/SIMState.swift" \
    "$openu60_root/mobile/ios/Tests/SIMStateTests.swift" -o "$openu60_work/tests"
"$openu60_work/tests"
