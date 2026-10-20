#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
    echo 'Usage: build_native_callkit_probe.sh <signed-app> <signing-identity>' >&2
    exit 2
fi
openu60_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
xcodebuild -project "$openu60_root/mobile/ios/OpenU60/OpenU60.xcodeproj" -scheme OpenU60 \
    -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$openu60_root/target/ios-native-probe-derived" \
    -clonedSourcePackagesDirPath "$openu60_root/target/ios-packages" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG OPENU60_NATIVE_CALLKIT_PROBE' \
    DEVELOPMENT_TEAM="$(codesign -d --entitlements :- "$1" 2>/dev/null | python3 -c 'import plistlib,sys;print(plistlib.loads(sys.stdin.buffer.read())["com.apple.developer.team-identifier"])')" \
    CODE_SIGN_IDENTITY="$2" build
openu60_app="$openu60_root/target/ios-native-probe-derived/Build/Products/Debug-iphoneos/OpenU60.app"
codesign --verify --deep --strict "$openu60_app"
echo "Complete app with the optional verification sheet: $openu60_app"
echo 'Transfer the isolated phone fixture privately into Documents/openu60-native-probe.private.json.'
echo 'Launch explicitly with --native-callkit-probe. Back to OpenU60 restores the previous in-memory session.'
