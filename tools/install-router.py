#!/usr/bin/env python3
"""Install locally built calling artifacts through ADB without reading credentials."""
import argparse
import hashlib
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
HELPER_SHA = "14f02d6d8af581cf08102be83ecd08f332d529a5a4a38efc455e832fcd672f11"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", help="ADB device serial; otherwise exactly one device must be available")
    parser.add_argument("--restart", action="store_true", required=True,
                        help="acknowledge that the installed agent will be restarted; run while the modem is idle")
    args = parser.parse_args()
    agent = ROOT / "target/aarch64-unknown-linux-musl/release/zte-agent"
    shim = ROOT / "target/audio-bridge/libopenu60-audio.so"
    digests = []
    for artifact in (agent, shim):
        data = artifact.read_bytes()
        if data[:6] != b"\x7fELF\x02\x01" or int.from_bytes(data[18:20], "little") != 183:
            raise RuntimeError(f"Expected an AArch64 ELF artifact: {artifact.name}")
        digests.append(hashlib.sha256(data).hexdigest())
    adb = ["adb"] + (["-s", args.serial] if args.serial else [])
    subprocess.run(adb + ["get-state"], check=True, capture_output=True)
    for artifact, remote in ((agent, "/tmp/openu60-agent.install"), (shim, "/tmp/openu60-audio.install")):
        subprocess.run(adb + ["push", str(artifact), remote], check=True)
    script = f'''set -eu
trap 'code=$?; printf "\\nOPENU60_INSTALL_EXIT:%s\\n" "$code"' EXIT
test "$(id -u)" = 0
test -x /data/local/tmp/start_zte_agent.sh
test "$(sha256sum /usr/bin/zte_route_hal_voice_test | cut -d ' ' -f1)" = {HELPER_SHA}
test "$(sha256sum /tmp/openu60-agent.install | cut -d ' ' -f1)" = {digests[0]}
test "$(sha256sum /tmp/openu60-audio.install | cut -d ' ' -f1)" = {digests[1]}
mkdir -p /data/openu60-calling
chmod 700 /data/openu60-calling
if test ! -e /data/zte-agent.before-remote-calling; then cp -p /data/zte-agent /data/zte-agent.before-remote-calling; fi
cp /tmp/openu60-agent.install /data/zte-agent.calling-new
cp /tmp/openu60-audio.install /data/openu60-calling/audio-new.so
chmod 700 /data/zte-agent.calling-new
chmod 600 /data/openu60-calling/audio-new.so
mv /data/zte-agent.calling-new /data/zte-agent
mv /data/openu60-calling/audio-new.so /data/openu60-calling/libopenu60-audio.so
if pidof zte-agent >/dev/null; then killall zte-agent; fi
sleep 1
/data/local/tmp/start_zte_agent.sh
sleep 2
pidof zte-agent >/dev/null
rm /tmp/openu60-agent.install /tmp/openu60-audio.install
'''
    result = subprocess.run(adb + ["shell", "sh", "-s"], input=script, text=True, capture_output=True, timeout=30)
    # Legacy adbd can return transport success for a failing remote shell.
    if result.returncode != 0 or not result.stdout.rstrip().endswith("OPENU60_INSTALL_EXIT:0"):
        raise RuntimeError("Router installation failed. The existing startup and credential files were preserved; check device connectivity and helper compatibility.")
    print("Installed the calling agent and audio adapter. Existing startup, APNs, and calling credentials were preserved.")


if __name__ == "__main__":
    main()
