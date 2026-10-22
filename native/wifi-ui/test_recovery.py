"""Exercise recovery with synthetic firmware, a real child process and real signals."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

SOURCE = Path(__file__).with_name("recovery.c")


class RecoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="openu60-recovery-")
        cls.root = Path(cls.temporary.name)
        cls.recovery = cls.root / "data/openu60-ui/recovery"
        cls.recovery.mkdir(parents=True)
        cls.init = cls.root / "etc/init.d/zte_topsw_devui"
        cls.init.parent.mkdir(parents=True)
        cls.ui = cls.root / "usr/bin/zte_topsw_devui"
        cls.ui.parent.mkdir(parents=True)
        cls.sdk = cls.root / "usr/lib/libzte_SDKowrt.so"
        cls.sdk.parent.mkdir(parents=True)
        (cls.root / "tmp").mkdir()
        cls.actions = cls.root / "actions"
        cls.init_bytes = f'''#!/bin/sh
test -z "${{LD_PRELOAD:-}}" || exit 90
echo "$1" >> '{cls.actions}'
if [ "$1" = start ] && [ "${{OPENU60_TEST_RESTART_HANG:-}}" = 1 ]; then
    sleep 30
fi
'''.encode()
        cls.init.write_bytes(cls.init_bytes)
        cls.init.chmod(0o755)
        fake = cls.root / "fake.c"
        fake.write_text(r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(void) {
    const char *mode = getenv("OPENU60_TEST_BEHAVIOR");
    if (mode && !strcmp(mode, "crash")) return 42;
    for (unsigned count = 1;; count++) {
        if (mode && !strcmp(mode, "delayed_exit") && count >= 50) return 0;
        if (mode && strstr(mode, "fault")) {
            FILE *fault = fopen(FAULT, "w");
            if (!fault) return 2;
            fprintf(fault, "%ld %u\n", (long)getpid() + (!strcmp(mode, "foreign_fault") ? 1 : 0),
                    !strcmp(mode, "unknown_fault") ? 999 : 6);
            fclose(fault);
        }
        if (!mode || (!strcmp(mode, "freeze") ? count < 3 : strcmp(mode, "hang"))) {
            FILE *f = fopen(HEARTBEAT, "w");
            if (!f) return 2;
            fprintf(f, "%ld %u\n", (long)getpid(), count);
            fclose(f);
        }
        usleep(10000);
    }
}
''')
        cls.compile(fake, cls.ui, [f'-DHEARTBEAT="{cls.root}/tmp/openu60-ui.heartbeat"',
                                 f'-DFAULT="{cls.root}/tmp/openu60-native-ui.fault"'])
        cls.sdk.write_bytes(b"synthetic SDK")
        preload = cls.root / "preload.c"
        preload.write_text("int synthetic_preload(void) { return 0; }\n")
        cls.compile(preload, cls.recovery / "trial.so", ["-shared", "-fPIC"])
        cls.candidate_sha = cls.sha(cls.recovery / "trial.so")
        cls.candidate_bytes = (cls.recovery / "trial.so").read_bytes()
        cls.guard = cls.root / "guard"
        cls.compile(SOURCE, cls.guard, [
            "-DOPENU60_RECOVERY_TEST", f'-DDEVICE_ROOT="{cls.root}"',
            f'-DINIT_SHA="{cls.sha(cls.init)}"', f'-DUI_SHA="{cls.sha(cls.ui)}"',
            f'-DSDK_SHA="{cls.sha(cls.sdk)}"', "-DTRIAL_MS=1500", "-DSTARTUP_MS=1000",
            "-DHEARTBEAT_MS=200", "-DCOMMAND_MS=1000", "-DPOLL_MS=10",
        ])
        for source, name in [(cls.ui, "stock-devui"), (cls.sdk, "stock-sdk.so"), (cls.init, "stock-init.sh")]:
            (cls.recovery / name).write_bytes(source.read_bytes())

    @staticmethod
    def compile(source, target, flags):
        subprocess.run(["cc", "-std=gnu11", "-Wall", "-Wextra", "-Werror", *flags,
                        str(source), "-o", str(target)], check=True, capture_output=True)

    @staticmethod
    def sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def setUp(self):
        self.init.write_bytes(self.init_bytes)
        self.actions.unlink(missing_ok=True)
        for path in (self.root / "tmp").iterdir():
            path.unlink()
        (self.recovery / "trial.so").write_bytes(self.candidate_bytes)
        for name in ["enabled.sha256", "running", "restore.request", "guard.new", "guard", "trial.so.new", "last-result"]:
            (self.recovery / name).unlink(missing_ok=True)

    def run_guard(self, *args, **environment):
        return subprocess.run([str(self.guard), *args], env={**os.environ, **environment},
                              capture_output=True, text=True, timeout=4)

    def assert_restored(self, result, returncode=0):
        self.assertEqual(result.returncode, returncode, result.stdout + result.stderr)
        self.assertEqual(self.init.read_bytes(), self.init_bytes)
        self.assertEqual(self.actions.read_text().splitlines()[-1], "start")
        self.assertFalse((self.root / "tmp/openu60-ui.heartbeat").exists())

    def test_healthy_trial_expires_without_changing_boot_path(self):
        result = self.run_guard("trial", self.candidate_sha)
        self.assertIn("trial deadline reached", result.stdout)
        self.assertEqual(self.actions.read_text().splitlines()[0], "stop")
        self.assert_restored(result)

    def test_crash_or_ui_freeze_restores_factory(self):
        for behavior, reason in [("crash", "trial process exited"), ("hang", "UI heartbeat stopped"),
                                 ("freeze", "UI heartbeat stopped")]:
            with self.subTest(behavior=behavior):
                self.setUp()
                result = self.run_guard("trial", self.candidate_sha, OPENU60_TEST_BEHAVIOR=behavior)
                self.assertIn(reason, result.stdout)
                self.assert_restored(result, returncode=1)

    def test_explicit_fault_recovers_even_if_a_heartbeat_is_still_advancing(self):
        result = self.run_guard("trial", self.candidate_sha, OPENU60_TEST_BEHAVIOR="reported_fault")
        self.assertIn("native Home layout deadline reached", result.stdout)
        self.assert_restored(result, returncode=1)

    def test_foreign_or_unknown_fault_cannot_stop_a_healthy_candidate(self):
        for behavior in ["foreign_fault", "unknown_fault"]:
            with self.subTest(behavior=behavior):
                self.setUp()
                result = self.run_guard("trial", self.candidate_sha, OPENU60_TEST_BEHAVIOR=behavior)
                self.assertIn("trial deadline reached", result.stdout)
                self.assert_restored(result)

    def start_trial(self, permanent=False):
        if permanent:
            enabled = self.run_guard("enable", self.candidate_sha)
            self.assertEqual(enabled.returncode, 0, enabled.stderr)
        args = ["serve"] if permanent else ["trial", self.candidate_sha]
        child = subprocess.Popen([str(self.guard), *args],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.kill_if_alive, child)
        deadline = time.monotonic() + 2
        while not (self.root / "tmp/openu60-ui.heartbeat").exists():
            if time.monotonic() >= deadline or child.poll() is not None:
                self.fail("Synthetic UI did not start")
            time.sleep(0.005)
        return child

    @staticmethod
    def kill_if_alive(child):
        if child.poll() is None:
            child.send_signal(signal.SIGCONT)
            child.send_signal(signal.SIGTERM)
            child.communicate(timeout=4)

    def test_independent_manual_restore_stops_trial(self):
        child = self.start_trial()
        result = self.run_guard("restore")
        stdout, stderr = child.communicate(timeout=4)
        self.assertEqual(child.returncode, 0, stderr)
        self.assertIn("manual restore requested", stdout)
        self.assert_restored(result)

    def test_supervisor_signal_recovers_factory(self):
        child = self.start_trial()
        child.send_signal(signal.SIGTERM)
        stdout, stderr = child.communicate(timeout=4)
        result = subprocess.CompletedProcess(child.args, child.returncode, stdout, stderr)
        self.assertIn("supervisor interrupted", stdout)
        self.assert_restored(result, returncode=1)

    @unittest.skipUnless(sys.platform == "linux", "Linux parent-death signal contract")
    def test_guardian_sigkill_cannot_leave_candidate_running(self):
        child = self.start_trial()
        reported = (self.root / "tmp/openu60-ui.heartbeat").read_text().split()
        candidate = int(reported[0])
        child.kill()
        child.communicate(timeout=4)
        deadline = time.monotonic() + 2
        status = Path(f"/proc/{candidate}/status")
        while status.exists() and "State:\tZ" not in status.read_text():
            if time.monotonic() >= deadline:
                self.fail("Candidate survived its guardian")
            time.sleep(0.01)
        self.assert_restored(self.run_guard("restore"))

    def test_wrong_candidate_hash_is_rejected_before_stop(self):
        result = self.run_guard("trial", "0" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.actions.exists())
        self.assertEqual(self.init.read_bytes(), self.init_bytes)

    @unittest.skipUnless(sys.platform == "linux", "Linux display/input process ownership")
    def test_trial_waits_for_factory_process_to_release_devices(self):
        original = subprocess.Popen([str(self.ui)], env={**os.environ, "OPENU60_TEST_BEHAVIOR": "delayed_exit"})
        self.addCleanup(self.kill_if_alive, original)
        guard = subprocess.Popen([str(self.guard), "trial", self.candidate_sha],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.kill_if_alive, guard)
        heartbeat = self.root / "tmp/openu60-ui.heartbeat"
        deadline = time.monotonic() + 3
        while True:
            try:
                fields = heartbeat.read_text().split()
            except FileNotFoundError:
                fields = []
            if fields and int(fields[0]) != original.pid:
                self.assertIsNotNone(original.poll(), "Candidate started while the factory process still owned devices")
                break
            if time.monotonic() >= deadline or guard.poll() is not None:
                self.fail("Candidate did not start after factory exit")
            time.sleep(0.005)
        stdout, stderr = guard.communicate(timeout=4)
        self.assert_restored(subprocess.CompletedProcess(guard.args, guard.returncode, stdout, stderr))

    @unittest.skipUnless(sys.platform == "linux", "Linux display/input process ownership")
    def test_stopped_factory_process_is_forced_to_release_devices(self):
        original = subprocess.Popen([str(self.ui)], env={**os.environ, "OPENU60_TEST_BEHAVIOR": "hang"})
        self.addCleanup(self.kill_if_alive, original)
        result = self.run_guard("trial", self.candidate_sha)
        self.assert_restored(result)
        self.assertEqual(original.poll(), -signal.SIGKILL)

    def test_restart_timeout_keeps_factory_startup_durable(self):
        self.init.write_bytes(b"broken trial startup")
        result = self.run_guard("restore", OPENU60_TEST_RESTART_HANG="1")
        self.assertIn("deadline", result.stderr)
        self.assert_restored(result, returncode=1)

    def test_wrong_factory_backup_prevents_trial(self):
        backup = self.recovery / "stock-sdk.so"
        original = backup.read_bytes()
        try:
            backup.write_bytes(b"unexpected firmware")
            result = self.run_guard("trial", self.candidate_sha)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.actions.exists())
        finally:
            backup.write_bytes(original)

    def test_supervised_service_survives_trial_deadline_and_clean_stop_preserves_enable(self):
        child = self.start_trial(permanent=True)
        time.sleep(1.6)
        self.assertIsNone(child.poll(), "Permanent service expired as a trial")
        self.assertTrue((self.recovery / "running").exists())
        child.send_signal(signal.SIGTERM)
        stdout, stderr = child.communicate(timeout=4)
        self.assert_restored(subprocess.CompletedProcess(child.args, child.returncode, stdout, stderr))
        self.assertEqual((self.recovery / "enabled.sha256").read_text(), self.candidate_sha)
        self.assertFalse((self.recovery / "running").exists())
        self.assertEqual(json.loads((self.recovery / "last-result").read_text())["state"], "clean-stop")

    def test_supervised_failure_disables_before_factory_recovery(self):
        for behavior in ["crash", "hang", "freeze"]:
            with self.subTest(behavior=behavior):
                self.setUp()
                self.assertEqual(self.run_guard("enable", self.candidate_sha).returncode, 0)
                result = self.run_guard("serve", OPENU60_TEST_BEHAVIOR=behavior)
                self.assert_restored(result, returncode=1)
                self.assertFalse((self.recovery / "enabled.sha256").exists())
                self.assertFalse((self.recovery / "running").exists())
                outcome = json.loads((self.recovery / "last-result").read_text())
                self.assertEqual(outcome["state"], "trial process exited" if behavior == "crash" else "UI heartbeat stopped")
                if behavior == "hang":
                    self.assertEqual(outcome["sequence"], 0)
                    self.assertGreaterEqual(outcome["heartbeatAgeMs"], 1000)
                elif behavior == "freeze":
                    self.assertGreater(outcome["sequence"], 0)
                    self.assertGreaterEqual(outcome["heartbeatAgeMs"], 200)
                previous = self.actions.read_text()
                self.assertEqual(self.run_guard("serve").returncode, 0)
                self.assertEqual(self.actions.read_text(), previous, "Disabled service must not start another candidate")

    @unittest.skipUnless(sys.platform == "linux", "Linux shutdown signal ordering")
    def test_shutdown_preserves_enable_when_child_exits_before_guard_but_faults_still_disarm(self):
        for child_signal, keep_enabled in [(signal.SIGTERM, True), (signal.SIGSEGV, False)]:
            with self.subTest(child_signal=child_signal):
                self.setUp()
                guard = self.start_trial(permanent=True)
                candidate = int((self.root / "tmp/openu60-ui.heartbeat").read_text().split()[0])
                guard.send_signal(signal.SIGSTOP)
                os.kill(candidate, child_signal)
                deadline = time.monotonic() + 1
                status = Path(f"/proc/{candidate}/status")
                while status.exists() and "State:\tZ" not in status.read_text():
                    if time.monotonic() >= deadline:
                        self.fail("Synthetic UI did not exit before its stopped guardian")
                    time.sleep(0.005)
                guard.send_signal(signal.SIGTERM)
                guard.send_signal(signal.SIGCONT)
                stdout, stderr = guard.communicate(timeout=4)
                self.assert_restored(subprocess.CompletedProcess(guard.args, guard.returncode, stdout, stderr),
                                     returncode=0 if keep_enabled else 1)
                self.assertEqual((self.recovery / "enabled.sha256").exists(), keep_enabled)

    def test_manual_restore_disables_supervised_startup(self):
        child = self.start_trial(permanent=True)
        self.assert_restored(self.run_guard("restore"))
        stdout, stderr = child.communicate(timeout=4)
        self.assertEqual(child.returncode, 0, stdout + stderr)
        self.assertFalse((self.recovery / "enabled.sha256").exists())
        self.assertFalse((self.recovery / "running").exists())

    def test_unclean_previous_session_falls_back_without_starting_candidate(self):
        self.assertEqual(self.run_guard("enable", self.candidate_sha).returncode, 0)
        (self.recovery / "running").write_text("starting\n")
        self.assert_restored(self.run_guard("serve"))
        self.assertEqual(self.actions.read_text().splitlines(), ["stop", "start"])
        self.assertFalse((self.recovery / "enabled.sha256").exists())
        self.assertEqual(json.loads((self.recovery / "last-result").read_text())["state"], "unclean-session")

    @unittest.skipUnless(sys.platform == "linux", "Linux parent-death and respawn contract")
    def test_guardian_sigkill_is_recovered_by_next_service_run(self):
        child = self.start_trial(permanent=True)
        child.kill(); child.communicate(timeout=4)
        result = self.run_guard("serve")
        self.assert_restored(result)
        self.assertFalse((self.recovery / "enabled.sha256").exists())

    def test_changed_enabled_candidate_is_disarmed_before_stopping_stock(self):
        self.assertEqual(self.run_guard("enable", self.candidate_sha).returncode, 0)
        (self.recovery / "enabled.sha256").write_text("0" * 64)
        result = self.run_guard("serve")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.actions.exists())
        self.assertFalse((self.recovery / "enabled.sha256").exists())

    def test_component_publication_verifies_hash_and_preserves_rejected_candidate(self):
        staged = self.recovery / "trial.so.new"
        staged.write_bytes(self.candidate_bytes + b"new build")
        result = self.run_guard("stage-candidate", "0" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.recovery / "trial.so").read_bytes(), self.candidate_bytes)
        result = self.run_guard("stage-candidate", self.sha(staged))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.recovery / "trial.so").read_bytes(), self.candidate_bytes + b"new build")

    def test_enabled_candidate_cannot_be_replaced_or_started_as_a_trial(self):
        self.assertEqual(self.run_guard("enable", self.candidate_sha).returncode, 0)
        (self.recovery / "trial.so.new").write_bytes(self.candidate_bytes + b"new build")
        self.assertNotEqual(self.run_guard("stage-candidate", self.sha(self.recovery / "trial.so.new")).returncode, 0)
        self.assertNotEqual(self.run_guard("trial", self.candidate_sha).returncode, 0)
        self.assertEqual((self.recovery / "trial.so").read_bytes(), self.candidate_bytes)
        self.assertFalse(self.actions.exists())

    def test_guard_publication_is_blocked_while_a_supervisor_is_active(self):
        staged = self.recovery / "guard.new"
        staged.write_bytes(self.guard.read_bytes())
        previous = self.recovery / "guard"
        previous.write_bytes(b"previous guard")
        child = self.start_trial()
        result = self.run_guard("promote-guard", self.sha(staged))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(previous.read_bytes(), b"previous guard")
        self.assert_restored(self.run_guard("restore"))
        child.communicate(timeout=4)
        result = self.run_guard("promote-guard", self.sha(staged))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(previous.read_bytes(), self.guard.read_bytes())


if __name__ == "__main__":
    unittest.main()
