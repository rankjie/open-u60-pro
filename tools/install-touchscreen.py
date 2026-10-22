#!/usr/bin/env python3
"""Install the supervised native screen, run a bounded trial, or restore stock."""
import argparse
import hashlib
import json
import shlex
from pathlib import Path
import subprocess
import time

INIT = "/etc/init.d/zte_topsw_devui"
RECOVERY = "/data/openu60-ui/recovery"
SCREEN_SERVICE = "/etc/init.d/openu60-screen"
SCREEN_BOOT_ENTRY = SCREEN_SERVICE + " start >/tmp/openu60-screen.boot.log 2>&1 &"
FACTORY_FILES = {
    "stock-init.sh": (INIT, "a30da6481637f1fd94e037373d406e574be7e722937a4965325086740be67e35"),
    "stock-devui": ("/usr/bin/zte_topsw_devui", "7a158227890ddd5dc247ab1d198cef3cf69a13d2667892a980effc2a9f509ca0"),
    "stock-sdk.so": ("/usr/lib/libzte_SDKowrt.so", "7847ec604e7549c76da1b9e94326ce525ba7ea1fd51ee8e4422668d63f894fb7"),
}
ROOT = Path(__file__).resolve().parents[1]


def shell(adb, script, timeout=15):
    # This firmware's ADB shell does not reliably forward stdin EOF to sh -s.
    result = subprocess.run(adb + ["shell", "sh", "-s"], input=script + "\nexit 0\n", text=True,
                            capture_output=True, timeout=timeout)
    if result.returncode or "OPENU60_SCREEN_EXIT:0" not in result.stdout:
        prefixes = ("Trial exit code:", "Trial termination signal:", "Restoring factory screen:",
                    "Recovery command exceeded", "UI heartbeat", "Trial rejected", "Factory checksum")
        context = [line.strip() for line in result.stdout.splitlines() if line.startswith(prefixes)]
        suffix = ": " + "; ".join(context[-4:]) if context else ""
        raise RuntimeError("Screen command failed; native UI recovery is required" + suffix)
    return result.stdout


def prepare(adb):
    binary = ROOT / "target/wifi-ui/openu60-ui-recovery"
    if not binary.is_file():
        raise RuntimeError("Build the independent recovery process with native/wifi-ui/build-recovery.sh first")
    guard_sha = hashlib.sha256(binary.read_bytes()).hexdigest()
    # These three public firmware files contain no settings or credential stores.
    # Existing backups are immutable; a mismatch aborts instead of replacing them.
    statements = ["set -eu", "umask 077",
                  "trap 'code=$?; printf \"\\nOPENU60_SCREEN_EXIT:%s\\n\" \"$code\"' EXIT",
                  "test \"$(id -u)\" = 0", f"mkdir -p {RECOVERY}",
                  f"chmod 700 /data/openu60-ui {RECOVERY}"]
    for name, (source, checksum) in FACTORY_FILES.items():
        destination = f"{RECOVERY}/{name}"
        statements.extend([
            f"test \"$(sha256sum {source} | cut -d ' ' -f1)\" = {checksum}",
            f"if test -e {destination}; then",
            f"  test \"$(sha256sum {destination} | cut -d ' ' -f1)\" = {checksum}",
            "else", f"  cp -p {source} {destination}.new",
            f"  test \"$(sha256sum {destination}.new | cut -d ' ' -f1)\" = {checksum}",
            f"  chmod 500 {destination}.new", f"  mv {destination}.new {destination}", "fi",
        ])
    statements.extend(["sync", "exit 0", ""])
    shell(adb, "\n".join(statements), 30)
    subprocess.run(adb + ["push", str(binary), f"{RECOVERY}/guard.new"],
                   check=True, capture_output=True, timeout=30)
    shell(adb, f'''set -eu
trap 'code=$?; printf "\\nOPENU60_SCREEN_EXIT:%s\\n" "$code"' EXIT
chmod 500 {RECOVERY}/guard.new
test "$(sha256sum {RECOVERY}/guard.new | cut -d ' ' -f1)" = {guard_sha}
{RECOVERY}/guard.new promote-guard {guard_sha}
{RECOVERY}/guard status
''', 30)
    local = ROOT / "firmware/ui-recovery/7a158227890d"
    local.mkdir(parents=True, exist_ok=True)
    for name, (_, checksum) in FACTORY_FILES.items():
        destination = local / name
        if not destination.exists():
            temporary = destination.with_suffix(".new")
            subprocess.run(adb + ["pull", f"{RECOVERY}/{name}", str(temporary)],
                           check=True, capture_output=True, timeout=30)
            if hashlib.sha256(temporary.read_bytes()).hexdigest() != checksum:
                raise RuntimeError(f"Local recovery backup checksum failed: {name}")
            temporary.replace(destination)
        elif hashlib.sha256(destination.read_bytes()).hexdigest() != checksum:
            raise RuntimeError(f"Existing local backup checksum failed: {name}")
    print("Factory program, SDK and startup backed up on the router and Mac; checksums verified.", flush=True)
    print("Recovery supervisor installed. Factory startup and the running screen were not changed.", flush=True)


def rollback(adb):
    configure_boot(adb, False)
    shell(adb, f'''set -eu
trap 'code=$?; printf "\\nOPENU60_SCREEN_EXIT:%s\\n" "$code"' EXIT
if test -x {SCREEN_SERVICE}; then {SCREEN_SERVICE} disable; fi
''')
    available = shell(adb, f'''set -eu
trap 'code=$?; printf "\\nOPENU60_SCREEN_EXIT:%s\\n" "$code"' EXIT
if test -x {RECOVERY}/guard; then echo GUARD_PRESENT; fi
''')
    if "GUARD_PRESENT" in available.splitlines():
        shell(adb, f'''set -eu
trap 'code=$?; printf "\\nOPENU60_SCREEN_EXIT:%s\\n" "$code"' EXIT
{RECOVERY}/guard restore
if test -x {SCREEN_SERVICE}; then {SCREEN_SERVICE} stop; fi
''', 45)
        return
    # Persist the recovery before restarting: the previous restart timed out
    # before the installer reached its rollback path.
    shell(adb, f'''set -eu
trap 'code=$?; printf "\\nOPENU60_SCREEN_EXIT:%s\\n" "$code"' EXIT
test -f /data/openu60-ui/stock-init.sh
test "$(sha256sum /data/openu60-ui/stock-init.sh | cut -d ' ' -f1)" = {FACTORY_FILES['stock-init.sh'][1]}
if test -e /data/openu60-ui/libopenu60-ui.so; then
    mv /data/openu60-ui/libopenu60-ui.so /data/openu60-ui/libopenu60-ui.disabled.so
fi
cp -p /data/openu60-ui/stock-init.sh {INIT}.restore
chmod 755 {INIT}.restore
mv {INIT}.restore {INIT}
sync
''')
    print("Factory startup restored; the extension is disabled on future boots.", flush=True)
    shell(adb, f'''set -eu
trap 'code=$?; printf "\\nOPENU60_SCREEN_EXIT:%s\\n" "$code"' EXIT
{INIT} restart
''', 20)


def stage_candidate(adb):
    candidate = ROOT / "target/wifi-ui/libopenu60-native-ui.so"
    if not candidate.is_file():
        raise RuntimeError("Build the native LVGL replacement with native/wifi-ui/build-native.sh first")
    prepare(adb)
    checksum = hashlib.sha256(candidate.read_bytes()).hexdigest()
    subprocess.run(adb + ["push", str(candidate), f"{RECOVERY}/trial.so.new"],
                   check=True, capture_output=True, timeout=30)
    shell(adb, f'''set -eu
trap 'code=$?; printf "\\nOPENU60_SCREEN_EXIT:%s\\n" "$code"' EXIT
test "$(sha256sum {RECOVERY}/trial.so.new | cut -d ' ' -f1)" = {checksum}
{RECOVERY}/guard stage-candidate {checksum}
''')
    return checksum


def install_native(adb):
    rollback(adb)
    checksum = stage_candidate(adb)
    service = ROOT / "scripts/openu60-screen.init"
    service_sha = hashlib.sha256(service.read_bytes()).hexdigest()
    subprocess.run(adb + ["push", str(service), f"{SCREEN_SERVICE}.new"],
                   check=True, capture_output=True, timeout=30)
    try:
        shell(adb, f'''set -eu
trap 'code=$?; printf "\\nOPENU60_SCREEN_EXIT:%s\\n" "$code"' EXIT
test "$(sha256sum {SCREEN_SERVICE}.new | cut -d ' ' -f1)" = {service_sha}
chmod 755 {SCREEN_SERVICE}.new
mv {SCREEN_SERVICE}.new {SCREEN_SERVICE}
sync
{RECOVERY}/guard enable {checksum}
{SCREEN_SERVICE} disable
''', 30)
        configure_boot(adb, True)
        shell(adb, f'''set -eu
trap 'code=$?; printf "\\nOPENU60_SCREEN_EXIT:%s\\n" "$code"' EXIT
{SCREEN_SERVICE} start
''', 30)
        wait_for_native(adb)
    except (RuntimeError, subprocess.SubprocessError, KeyboardInterrupt):
        rollback(adb)
        raise
    print("Supervised native screen installed and started; factory program, SDK and init are unchanged.", flush=True)


def boot_entry_script(enabled, path="/etc/rc.local"):
    # Keep the mixed startup file opaque, as in the existing ADB installer.
    # Round-trip hashes prove that the owned line is the only byte change.
    return r'''set -eu
umask 077
staged=''
trap 'code=$?; if test -n "$staged"; then rm -f "$staged"; fi; printf "\nOPENU60_SCREEN_EXIT:%s\n" "$code"' EXIT
target=__TARGET__
entry='__ENTRY__'
action=__ACTION__
count=$(grep -Fxc "$entry" "$target" || true)
test "$count" -le 1
if { test "$action" = add && test "$count" = 0; } || { test "$action" = remove && test "$count" = 1; }; then
    test "$(grep -c '^exit 0$' "$target")" = 1
    original=$(sha256sum "$target" | cut -d ' ' -f1)
    permissions=$(stat -c '%a' "$target")
    staged=$(mktemp "$target.openu60.XXXXXX")
    if test "$action" = add; then
        awk -v entry="$entry" '$0 == "exit 0" {print entry} {print}' "$target" > "$staged"
        recovered=$(awk -v entry="$entry" '$0 != entry {print}' "$staged" | sha256sum | cut -d ' ' -f1)
    else
        awk -v entry="$entry" '$0 != entry {print}' "$target" > "$staged"
        recovered=$(awk -v entry="$entry" '$0 == "exit 0" {print entry} {print}' "$staged" | sha256sum | cut -d ' ' -f1)
    fi
    test "$original" = "$recovered"
    sh -n "$staged"
    chmod "$permissions" "$staged"
    mv "$staged" "$target"
    staged=''
    sync
fi
'''.replace("__TARGET__", shlex.quote(str(path))).replace("__ENTRY__", SCREEN_BOOT_ENTRY).replace("__ACTION__", "add" if enabled else "remove")


def configure_boot(adb, enabled):
    shell(adb, boot_entry_script(enabled))


def wait_for_native(adb):
    deadline = time.monotonic() + 25
    previous = None
    while time.monotonic() < deadline:
        result = subprocess.run(adb + ["shell", "cat", "/tmp/openu60-native-ui.status"],
                                text=True, capture_output=True, timeout=5)
        try:
            current = json.loads(result.stdout)
        except json.JSONDecodeError:
            current = None
        if current is not None:
            if not isinstance(current, dict) or any(type(current.get(key)) is not int or current[key] <= 0 for key in ["pid", "sequence"]):
                raise RuntimeError("Native screen returned invalid heartbeat metadata")
            if previous and current["pid"] == previous["pid"] and current["sequence"] > previous["sequence"]:
                return
            previous = current
        time.sleep(0.5)
    raise RuntimeError("Supervised screen did not publish an advancing UI-thread heartbeat")


def trial_native(adb):
    checksum = stage_candidate(adb)
    print("Starting one 120-second trial. Factory startup remains unchanged; the guardian restores it automatically.", flush=True)
    try:
        shell(adb, f'''set -eu
trap 'code=$?; printf "\\nOPENU60_SCREEN_EXIT:%s\\n" "$code"' EXIT
{RECOVERY}/guard trial {checksum}
''', 160)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        rollback(adb)
        raise
    print("Trial ended; the guardian requested factory restoration. Verify the screen and touch before installation.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--restore", action="store_true")
    modes.add_argument("--prepare-recovery", action="store_true")
    modes.add_argument("--trial-native", action="store_true", help="one supervised 120-second trial; never changes boot startup")
    modes.add_argument("--install-native", action="store_true", help="enable the independently supervised native screen at boot")
    args = parser.parse_args()
    if not args.restore and not args.prepare_recovery and not args.trial_native and not args.install_native:
        parser.error("Choose --install-native, --trial-native, --prepare-recovery or --restore.")
    adb = ["adb"] + (["-s", args.serial] if args.serial else [])
    subprocess.run(adb + ["get-state"], check=True, capture_output=True)
    if args.prepare_recovery:
        prepare(adb)
        return
    if args.trial_native:
        trial_native(adb)
        return
    if args.install_native:
        install_native(adb)
        return
    rollback(adb)
    print("Factory screen restart requested; verify display and touch on the device.")


if __name__ == "__main__":
    main()
