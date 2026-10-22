#!/usr/bin/env python3
"""Enable USB debugging at boot through the router's existing rc.local path."""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial")
    args = parser.parse_args()
    adb = ["adb"] + (["-s", args.serial] if args.serial else [])
    source = Path(__file__).resolve().parents[1] / "scripts/openu60-adb.init"
    subprocess.run(adb + ["push", str(source), "/tmp/openu60-adb.init"], check=True, capture_output=True)
    # rc.local is kept opaque. Verify that removing our one added line restores
    # its exact original bytes before replacing it; never print its contents.
    script = r'''set -eu
umask 077
trap 'code=$?; if [ -n "${staged:-}" ]; then rm -f "$staged"; fi; printf "\nOPENU60_ADB_BOOT_EXIT:%s\n" "$code"' EXIT
test "$(id -u)" = 0
sh -n /tmp/openu60-adb.init
entry='/etc/init.d/openu60-adb start >/tmp/openu60-adb.boot.log 2>&1 &'
if ! grep -Fqx "$entry" /etc/rc.local; then
    test "$(grep -c '^exit 0$' /etc/rc.local)" = 1
    original=$(sha256sum /etc/rc.local | cut -d ' ' -f1)
    permissions=$(stat -c '%a' /etc/rc.local)
    staged=$(mktemp /etc/rc.local.openu60.XXXXXX)
    awk -v entry="$entry" '$0 == "exit 0" {print entry} {print}' /etc/rc.local > "$staged"
    sh -n "$staged"
    recovered=$(awk -v entry="$entry" '$0 != entry {print}' "$staged" | sha256sum | cut -d ' ' -f1)
    test "$original" = "$recovered"
    chmod "$permissions" "$staged"
    mv "$staged" /etc/rc.local
    staged=''
fi
cp /tmp/openu60-adb.init /etc/init.d/openu60-adb.new
chmod 755 /etc/init.d/openu60-adb.new
mv /etc/init.d/openu60-adb.new /etc/init.d/openu60-adb
/etc/init.d/openu60-adb disable
/etc/init.d/openu60-adb start
sync
exit 0
'''
    result = subprocess.run(adb + ["shell", "sh", "-s"], input=script, text=True,
                            capture_output=True, timeout=45)
    if result.returncode or not result.stdout.rstrip().endswith("OPENU60_ADB_BOOT_EXIT:0"):
        raise RuntimeError("ADB boot setup failed; verify the connection and USB mode")
    print("ADB boot entry installed; existing rc.local contents were preserved.")


if __name__ == "__main__":
    main()
