from pathlib import Path
import subprocess
import tempfile
import unittest


INIT = Path(__file__).resolve().parents[1] / "scripts/openu60-wms-events.init"


class WMSEventGuardTests(unittest.TestCase):
    def run_guard(self, health):
        source = f""". '{INIT}'
log() {{ echo "LOG:$1"; }}
rollback() {{ echo FACTORY_RESTORED; }}
sleep() {{ :; }}
{health}
healthcheck
"""
        return subprocess.run(["sh"], input=source, text=True, capture_output=True, timeout=3)

    def test_failed_start_restores_factory_and_reports_failure(self):
        result = self.run_guard("healthy() { return 1; }")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.count("FACTORY_RESTORED"), 1)

    def test_service_failure_after_start_also_restores_factory(self):
        result = self.run_guard("calls=0; healthy() { calls=$((calls+1)); test \"$calls\" -eq 1; }")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.count("FACTORY_RESTORED"), 1)

    def test_recovered_transient_failure_does_not_disable_healthy_service(self):
        result = self.run_guard("calls=0; healthy() { calls=$((calls+1)); test \"$calls\" -ne 3 && test \"$calls\" -ne 4; }")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "LOG:healthy\n")

    def test_rollback_persists_disable_then_stops_unmounts_and_starts_factory(self):
        with tempfile.TemporaryDirectory() as directory:
            source = f""". '{INIT}'
state='{directory}'
active=1
log() {{ echo "LOG:$1"; }}
mounted() {{ return 0; }}
running() {{ test "$active" -eq 1; }}
wms_service() {{
    test -e "$state/disabled" || exit 42
    echo "SERVICE:$1"
    if test "$1" = stop; then active=0; fi
}}
umount() {{ test "$active" -eq 0 || exit 43; echo UNMOUNT; }}
rollback
"""
            result = subprocess.run(["sh"], input=source, text=True, capture_output=True, timeout=3)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "SERVICE:stop\nUNMOUNT\nSERVICE:start\nLOG:factory_restored\n")
            self.assertTrue((Path(directory) / "disabled").exists())


if __name__ == "__main__":
    unittest.main()
