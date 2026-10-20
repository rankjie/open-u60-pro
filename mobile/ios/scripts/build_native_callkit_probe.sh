#!/bin/sh
set -eu
if [ "$#" -ne 3 ]; then
    echo 'Usage: build_native_callkit_probe.sh <signed-app> <signing-identity> <private-LAN-ws-URL>' >&2
    exit 2
fi
openu60_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
openu60_work="$openu60_root/target/native-callkit-probe"
mkdir -p "$openu60_work"
xcodebuild -project "$openu60_root/mobile/ios/OpenU60/OpenU60.xcodeproj" -scheme OpenU60 \
    -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$openu60_root/target/ios-native-probe-derived" \
    -clonedSourcePackagesDirPath "$openu60_root/target/ios-packages" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG OPENU60_NATIVE_CALLKIT_PROBE' \
    DEVELOPMENT_TEAM="$(codesign -d --entitlements :- "$1" 2>/dev/null | python3 -c 'import plistlib,sys;print(plistlib.loads(sys.stdin.buffer.read())["com.apple.developer.team-identifier"])')" \
    CODE_SIGN_IDENTITY='Apple Development' build
ditto "$openu60_root/target/ios-native-probe-derived/Build/Products/Debug-iphoneos/OpenU60.app" "$openu60_work/OpenU60.app"
codesign -d --entitlements :- "$1" > "$openu60_work/entitlements.plist"
python3 - "$openu60_work/OpenU60.app/Info.plist" "$3" <<'PY'
import ipaddress, plistlib, sys, urllib.parse
url=urllib.parse.urlparse(sys.argv[2])
if url.scheme != 'ws' or not ipaddress.ip_address(url.hostname).is_private:
    raise SystemExit('The probe requires an explicit private LAN ws URL')
with open(sys.argv[1], 'rb') as f: info=plistlib.load(f)
# Preserve the full application. The fixture is an explicitly launched, closable sheet.
info['OpenU60NativeProbeURL']=sys.argv[2]
info['NSAppTransportSecurity']={'NSAllowsArbitraryLoads':True}
with open(sys.argv[1], 'wb') as f: plistlib.dump(info,f)
PY
codesign --force --sign "$2" --entitlements "$openu60_work/entitlements.plist" "$openu60_work/OpenU60.app"
codesign --verify --deep --strict "$openu60_work/OpenU60.app"
echo "Native probe built: $openu60_work/OpenU60.app"
echo 'Launch explicitly with --native-callkit-probe. Back to OpenU60 closes the fixture.'
