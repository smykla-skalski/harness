from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
CHECKOUT_ROOT = APP_ROOT.parents[1]
SCRIPT_PATH = APP_ROOT / "Scripts" / "monitor-xcodebuild.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class MonitorXcodebuildTests(unittest.TestCase):
    def run_script(
        self,
        *args: str,
        extra_env: dict[str, str] | None = None,
        inject_derived_data_path: bool = True,
        include_tuist: bool = True,
        cwd: Path | None = None,
        preexisting_lock_pid: int | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], str, Path]:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            fake_bin = temp_root / "bin"
            fake_bin.mkdir()
            derived_data_path = temp_root / "derived"
            tool_log = temp_root / "tool.log"

            if preexisting_lock_pid is not None:
                lock_dir = derived_data_path / ".harness-monitor-xcodebuild.lock"
                lock_dir.mkdir(parents=True)
                (lock_dir / "owner.env").write_text(
                    f"pid={preexisting_lock_pid}\nstarted_at=2026-01-01T00:00:00Z\n"
                )

            write_executable(
                fake_bin / "xcodebuild",
                f"""#!/bin/bash
set -euo pipefail
printf 'XCODEBUILD=%s\\n' "$*" >> "{tool_log}"
if [[ "${{FAKE_XCODEBUILD_FAIL:-0}}" == "1" ]]; then
  printf '/tmp/Fake.swift:1:1: error: synthetic failure\\n'
  exit 65
fi
""",
            )
            if include_tuist:
                write_executable(
                    fake_bin / "tuist",
                    f"""#!/bin/bash
set -euo pipefail
printf 'TUIST_PWD=%s\\nTUIST=%s\\n' "$PWD" "$*" >> "{tool_log}"
if [[ "${{1:-}}" != "xcodebuild" ]]; then
  echo "unexpected tuist subcommand: $*" >&2
  exit 1
fi
shift
"{fake_bin / "xcodebuild"}" "$@"
""",
                )

            env = os.environ.copy()
            for key in (
                "HARNESS_MONITOR_RUNTIME_PROFILE",
                "HARNESS_MONITOR_BUILD_LANE",
                "XCODEBUILD_DERIVED_DATA_PATH",
            ):
                env.pop(key, None)
            env.update(
                {
                    "PATH": f"{fake_bin}:/usr/bin:/bin",
                    "BASH_ENV": "/dev/null",
                    "HARNESS_SKIP_STALE_CHECK": "1",
                    "XCODEBUILD_BIN": str(fake_bin / "xcodebuild"),
                    "TMPDIR": str(temp_root),
                }
            )
            env.update(extra_env or {})

            command = ["bash", str(SCRIPT_PATH)]
            if inject_derived_data_path:
                command.extend(["-derivedDataPath", str(derived_data_path)])
            command.extend(args)
            completed = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                env=env,
                cwd=cwd,
            )
            log = tool_log.read_text() if tool_log.exists() else ""
            return completed, log, derived_data_path

    def test_uses_tuist_xcodebuild_and_releases_lock(self) -> None:
        completed, log, derived_data_path = self.run_script("-scheme", "HarnessMonitor", "build")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn(f"TUIST_PWD={APP_ROOT}", log)
        self.assertIn("TUIST=xcodebuild", log)
        self.assertIn(f"XCODEBUILD=-derivedDataPath {derived_data_path}", log)
        self.assertFalse((derived_data_path / ".harness-monitor-xcodebuild.lock").exists())

    def test_named_build_lane_injects_lane_derived_data_path(self) -> None:
        completed, log, _ = self.run_script(
            "-scheme",
            "HarnessMonitor",
            "build",
            inject_derived_data_path=False,
            extra_env={"HARNESS_MONITOR_BUILD_LANE": "Agent 42"},
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("xcode-derived-lanes/agent-42", log)

    def test_debug_lanes_disable_user_script_sandboxing_without_project_warning(self) -> None:
        completed, log, _ = self.run_script(
            "-scheme",
            "HarnessMonitor",
            "-configuration",
            "Debug",
            "build",
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("ENABLE_USER_SCRIPT_SANDBOXING=NO", log)

    def test_release_lanes_keep_user_script_sandboxing_project_default(self) -> None:
        completed, log, _ = self.run_script(
            "-scheme",
            "HarnessMonitor",
            "-configuration",
            "Release",
            "build",
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertNotIn("ENABLE_USER_SCRIPT_SANDBOXING=NO", log)

    def test_explicit_script_sandboxing_setting_is_not_overridden(self) -> None:
        completed, log, _ = self.run_script(
            "-scheme",
            "HarnessMonitor",
            "build",
            "ENABLE_USER_SCRIPT_SANDBOXING=YES",
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertNotIn("ENABLE_USER_SCRIPT_SANDBOXING=NO", log)
        self.assertIn("ENABLE_USER_SCRIPT_SANDBOXING=YES", log)

    def test_legacy_profile_env_is_rejected(self) -> None:
        completed, log, _ = self.run_script(
            "-scheme",
            "HarnessMonitor",
            "build",
            extra_env={"HARNESS_MONITOR_RUNTIME_PROFILE": "old"},
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(log, "")
        self.assertIn("HARNESS_MONITOR_RUNTIME_PROFILE is no longer supported", completed.stderr)

    def test_reports_lock_owner_when_lane_is_busy(self) -> None:
        sleeper = subprocess.Popen(["/bin/sleep", "10"])
        try:
            completed, log, _ = self.run_script(
                "-scheme",
                "HarnessMonitor",
                "build",
                extra_env={"XCODEBUILD_LOCK_WAIT_TIMEOUT_SECONDS": "1"},
                preexisting_lock_pid=sleeper.pid,
            )
        finally:
            sleeper.terminate()
            sleeper.wait(timeout=5)

        self.assertEqual(completed.returncode, 73)
        self.assertEqual(log, "")
        self.assertIn("Harness Monitor xcodebuild lane is busy", completed.stderr)
        self.assertIn(f"pid={sleeper.pid}", completed.stderr)

    def test_failure_persists_report(self) -> None:
        with tempfile.TemporaryDirectory() as report_dir:
            completed, _, _ = self.run_script(
                "-scheme",
                "HarnessMonitor",
                "build",
                extra_env={
                    "FAKE_XCODEBUILD_FAIL": "1",
                    "HARNESS_MONITOR_FAILURE_REPORT_DIR": report_dir,
                },
            )

            self.assertEqual(completed.returncode, 65)
            combined_output = completed.stdout + completed.stderr
            self.assertIn("xcodebuild-wrapper failure report:", combined_output)
            report_path = combined_output.strip().split(
                "xcodebuild-wrapper failure report: ", 1
            )[1].splitlines()[0]
            self.assertTrue(Path(report_path).exists())
            self.assertIn("synthetic failure", Path(report_path).read_text())


if __name__ == "__main__":
    unittest.main()
