from __future__ import annotations

import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
INSTALL_SCRIPT = REPO_ROOT / "scripts" / "launchd-fsmonitor-install.sh"
CLEANUP_SCRIPT = REPO_ROOT / "scripts" / "launchd-fsmonitor-cleanup.sh"
PLIST_TEMPLATE = REPO_ROOT / "scripts" / "launchd" / "com.smykla.harness.fsmonitor-cleanup.plist"


class LaunchdFsmonitorTests(unittest.TestCase):

    def test_install_script_is_executable(self) -> None:
        self.assertTrue(INSTALL_SCRIPT.is_file())
        self.assertTrue(os.access(INSTALL_SCRIPT, os.X_OK), "install script must be executable")

    def test_cleanup_script_is_executable(self) -> None:
        self.assertTrue(CLEANUP_SCRIPT.is_file())
        self.assertTrue(os.access(CLEANUP_SCRIPT, os.X_OK), "cleanup script must be executable")

    def test_plist_template_parses(self) -> None:
        with PLIST_TEMPLATE.open("rb") as f:
            data = plistlib.load(f)
        self.assertEqual(data["Label"], "com.smykla.harness.fsmonitor-cleanup")
        # Sunday=0 in launchd's calendar interval semantics.
        self.assertEqual(data["StartCalendarInterval"], {"Weekday": 0, "Hour": 3, "Minute": 15})
        self.assertIn("__SCRIPT_PATH__", data["ProgramArguments"][1])
        self.assertEqual(data["LowPriorityIO"], True)
        self.assertEqual(data["ProcessType"], "Background")
        self.assertFalse(data["RunAtLoad"])

    def test_help_action_does_not_modify_system(self) -> None:
        # Help mode prints usage and exits 0 without writing anywhere.
        completed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "help"],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("install", completed.stdout)
        self.assertIn("remove", completed.stdout)

    def test_unknown_action_exits_2(self) -> None:
        completed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "frobnicate"],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("unknown action", completed.stderr)

    def test_status_action_does_not_fail_when_not_installed(self) -> None:
        # status mode should always exit 0 regardless of whether the agent
        # is installed. We can't override the install path without an env
        # hook so this test exercises whatever state the host happens to
        # be in.
        completed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "status"],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_cleanup_script_handles_missing_repo_root(self) -> None:
        # If HARNESS_REPO_ROOT points to a non-existent dir, the cleanup
        # script must fail loudly rather than silently doing nothing.
        with tempfile.TemporaryDirectory() as tmp:
            log_dir = Path(tmp) / "logs"
            env = os.environ.copy()
            env["HARNESS_REPO_ROOT"] = "/nonexistent/path/that/does/not/exist"
            env["HARNESS_FSMONITOR_LOG_DIR"] = str(log_dir)
            completed = subprocess.run(
                ["bash", str(CLEANUP_SCRIPT)],
                capture_output=True, text=True, env=env, check=False,
            )
            # Cleanup script always writes a log file; check that the
            # fatal message went there.
            logs = list(log_dir.glob("cleanup-*.log"))
            self.assertTrue(logs, "cleanup script must write a log file even on failure")
            log_text = logs[0].read_text()
            self.assertIn("does not exist", log_text)

    def test_cleanup_script_runs_both_passes_on_a_valid_repo(self) -> None:
        # With a valid HARNESS_REPO_ROOT, both cleanup scripts are
        # invoked. We don't run the actual scripts (they touch system
        # state); we shim them to log markers.
        with tempfile.TemporaryDirectory() as tmp:
            shim_repo = Path(tmp) / "repo"
            shim_repo_scripts = shim_repo / "scripts"
            shim_repo_scripts.mkdir(parents=True)
            marker = Path(tmp) / "calls.log"
            for name in ("clean-stale-fsmonitor.sh", "disable-fsmonitor-dormant.sh"):
                (shim_repo_scripts / name).write_text(
                    f"#!/bin/bash\nprintf '%s %s\\n' '{name}' \"$*\" >> '{marker}'\n"
                )
                (shim_repo_scripts / name).chmod(0o755)
            log_dir = Path(tmp) / "logs"
            env = os.environ.copy()
            env["HARNESS_REPO_ROOT"] = str(shim_repo)
            env["HARNESS_FSMONITOR_LOG_DIR"] = str(log_dir)
            completed = subprocess.run(
                ["bash", str(CLEANUP_SCRIPT)],
                capture_output=True, text=True, env=env, check=False, timeout=30,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            calls = marker.read_text() if marker.exists() else ""
            self.assertIn("clean-stale-fsmonitor.sh --apply", calls)
            self.assertIn("disable-fsmonitor-dormant.sh --apply", calls)
            # And a log was written
            logs = list(log_dir.glob("cleanup-*.log"))
            self.assertTrue(logs)


if __name__ == "__main__":
    unittest.main()
