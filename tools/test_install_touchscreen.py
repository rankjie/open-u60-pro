"""Remote completion markers are authoritative on the inspected legacy ADB shell."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("install_touchscreen", Path(__file__).with_name("install-touchscreen.py"))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class ScreenCommandTests(unittest.TestCase):
    def test_remote_failure_is_not_hidden_by_adb_transport_success(self):
        for output in ["OPENU60_SCREEN_EXIT:1\n", "trial process exited\n", ""]:
            with self.subTest(output=output), patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output, "")):
                with self.assertRaises(RuntimeError):
                    installer.shell(["synthetic-adb"], "false")

    def test_completed_remote_command_preserves_its_result(self):
        with patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "restored\nOPENU60_SCREEN_EXIT:0\n", "")):
            self.assertEqual(installer.shell(["synthetic-adb"], "true"), "restored\nOPENU60_SCREEN_EXIT:0\n")

    def test_transport_failure_cannot_be_accepted_as_remote_success(self):
        with patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "OPENU60_SCREEN_EXIT:0\n", "unavailable")):
            with self.assertRaises(RuntimeError):
                installer.shell(["synthetic-adb"], "true")

    def test_failed_trial_retains_numeric_recovery_reason_without_unrelated_output(self):
        output = "unrelated diagnostic\nTrial termination signal: 11\nOPENU60_SCREEN_EXIT:1\n"
        with patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output, "")):
            with self.assertRaises(RuntimeError) as failure:
                installer.shell(["synthetic-adb"], "trial")
        self.assertIn("Trial termination signal: 11", str(failure.exception))
        self.assertNotIn("unrelated diagnostic", str(failure.exception))

    def test_native_startup_requires_an_advancing_sequence_from_the_same_process(self):
        samples = [
            '{"pid":10,"sequence":90}',
            '{"pid":11,"sequence":1}',
            '{"pid":11,"sequence":2}',
        ]
        replies = [subprocess.CompletedProcess([], 0, value, "") for value in samples]
        with patch.object(installer.subprocess, "run", side_effect=replies) as run, patch.object(installer.time, "sleep"):
            installer.wait_for_native(["synthetic-adb"])
        self.assertEqual(run.call_count, 3)

    def test_frozen_or_missing_heartbeat_expires(self):
        for output in ["", '{"pid":11,"sequence":1}']:
            with self.subTest(output=output), patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output, "")), patch.object(installer.time, "sleep"), patch.object(installer.time, "monotonic", side_effect=[0, 0, 1, 26]):
                with self.assertRaisesRegex(RuntimeError, "advancing UI-thread heartbeat"):
                    installer.wait_for_native(["synthetic-adb"])

    def test_invalid_heartbeat_is_an_explicit_contract_failure(self):
        for output in ['{"pid":true,"sequence":1}', '{"pid":11}', '[]']:
            with self.subTest(output=output), patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output, "")):
                with self.assertRaisesRegex(RuntimeError, "invalid heartbeat metadata"):
                    installer.wait_for_native(["synthetic-adb"])


@unittest.skipUnless(sys.platform == "linux", "Firmware shell tools and stat semantics")
class ScreenBootEntryTests(unittest.TestCase):
    def run_edit(self, enabled, path):
        return subprocess.run(["sh", "-c", installer.boot_entry_script(enabled, path)],
                              capture_output=True, text=True, timeout=5)

    def test_add_remove_and_retries_preserve_all_unrelated_bytes_and_permissions(self):
        for body in ["opaque_fixture='synthetic ${literal} `text`'", "# 合成测试数据\nopaque_fixture='synthetic value with spaces'"]:
            with self.subTest(body=body), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "startup with spaces"
                original = ("#!/bin/sh\n" + body + "\nexit 0\n").encode()
                path.write_bytes(original); path.chmod(0o700)
                self.assertEqual(self.run_edit(True, path).returncode, 0)
                added = path.read_bytes()
                self.assertEqual(added.count(installer.SCREEN_BOOT_ENTRY.encode()), 1)
                self.assertEqual(self.run_edit(True, path).returncode, 0)
                self.assertEqual(path.read_bytes(), added)
                self.assertEqual(self.run_edit(False, path).returncode, 0)
                self.assertEqual(path.read_bytes(), original)
                self.assertEqual(path.stat().st_mode & 0o777, 0o700)
                self.assertEqual(self.run_edit(False, path).returncode, 0)
                self.assertEqual(path.read_bytes(), original)

    def test_unsupported_startup_shape_is_rejected_without_changing_bytes(self):
        for original in [b"#!/bin/sh\n", b"exit 0\nexit 0\n", b"#!/bin/sh\nexit 0"]:
            with self.subTest(original=original), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "startup"
                path.write_bytes(original)
                self.assertNotEqual(self.run_edit(True, path).returncode, 0)
                self.assertEqual(path.read_bytes(), original)
                self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_ambiguous_owned_entries_are_rejected_without_changing_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "startup"
            original = (installer.SCREEN_BOOT_ENTRY + "\n" + installer.SCREEN_BOOT_ENTRY + "\nexit 0\n").encode()
            path.write_bytes(original)
            self.assertNotEqual(self.run_edit(False, path).returncode, 0)
            self.assertEqual(path.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
