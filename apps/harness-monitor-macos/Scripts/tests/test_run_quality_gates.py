from __future__ import annotations

import os
import platform
import plistlib
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = APP_ROOT / "Scripts" / "run-quality-gates.sh"


def expected_default_destination() -> str:
    machine = platform.machine()
    if machine in {"arm64", "x86_64"}:
        return f"platform=macOS,arch={machine},name=My Mac"
    return "platform=macOS,name=My Mac"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def write_entitlements(path: Path, payload: dict[str, object]) -> None:
    with path.open("wb") as handle:
        plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=False)


class RunQualityGatesTests(unittest.TestCase):
    def run_script(
        self,
        *,
        app_entitlements: Path | None = None,
        daemon_entitlements: Path | None = None,
        override_runner: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], str, str]:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            app_root = temp_root / "HarnessMonitor"
            scripts_root = app_root / "Scripts"
            scripts_root.mkdir(parents=True)
            derived_data_path = temp_root / "derived"
            runner_args_log = temp_root / "xcodebuild-args.log"
            rtk_calls_log = temp_root / "rtk-args.log"
            build_for_testing = scripts_root / "build-for-testing.sh"
            fake_log = temp_root / "log"

            write_executable(
                build_for_testing,
                f"""#!/bin/bash
set -euo pipefail
printf 'build-for-testing-script-called\\n' > "{runner_args_log}"
daemon_dir="${{XCODEBUILD_DERIVED_DATA_PATH}}/Build/Products/Debug/Harness Monitor.app/Contents/Helpers"
mkdir -p "$daemon_dir"
touch "$daemon_dir/harness"
chmod 755 "$daemon_dir/harness"
""",
            )
            write_executable(fake_log, "#!/bin/bash\nset -euo pipefail\n")

            env = os.environ.copy()
            env.update(
                {
                    "BUILD_FOR_TESTING_SCRIPT": str(build_for_testing),
                    "HARNESS_MONITOR_APP_ROOT": str(app_root),
                    "XCODEBUILD_DERIVED_DATA_PATH": str(derived_data_path),
                    "LOG_BIN": str(fake_log),
                    "HARNESS_MONITOR_APP_ENTITLEMENTS_PATH": str(
                        app_entitlements or APP_ROOT / "HarnessMonitor.entitlements"
                    ),
                    "HARNESS_MONITOR_DAEMON_ENTITLEMENTS_PATH": str(
                        daemon_entitlements or APP_ROOT / "HarnessMonitorDaemon.entitlements"
                    ),
                    "PATH": "/usr/bin:/bin",
                    "TMPDIR": str(temp_root),
                }
            )
            if override_runner:
                env["XCODEBUILD_RUNNER"] = str(temp_root / "override-runner.sh")

            completed = subprocess.run(
                ["bash", str(SCRIPT_PATH)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            args = runner_args_log.read_text() if runner_args_log.exists() else ""
            rtk_args = rtk_calls_log.read_text() if rtk_calls_log.exists() else ""
            return completed, args, rtk_args

    def test_build_for_testing_disables_code_signing(self) -> None:
        completed, runner_args, rtk_args = self.run_script()

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(runner_args, "build-for-testing-script-called\n")
        self.assertEqual(rtk_args, "")

    def test_fails_when_required_app_entitlement_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            entitlements_path = Path(tmp_dir) / "HarnessMonitor.entitlements"
            write_entitlements(
                entitlements_path,
                {
                    "com.apple.security.files.bookmarks.app-scope": True,
                    "com.apple.security.files.bookmarks.document-scope": True,
                },
            )

            completed, _, _ = self.run_script(app_entitlements=entitlements_path)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn(
            "missing app entitlement: user-selected.read-write",
            completed.stderr,
        )

    def test_fails_when_daemon_temporary_exception_is_present(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            entitlements_path = Path(tmp_dir) / "HarnessMonitorDaemon.entitlements"
            write_entitlements(
                entitlements_path,
                {
                    "com.apple.security.files.bookmarks.app-scope": True,
                    "com.apple.security.temporary-exception.files.home-relative-path": [
                        "~/Library/Application Support/harness"
                    ],
                },
            )

            completed, _, _ = self.run_script(daemon_entitlements=entitlements_path)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn(
            "daemon still has temporary-exception entitlement",
            completed.stderr,
        )

    def test_fails_when_daemon_user_selected_entitlement_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            entitlements_path = Path(tmp_dir) / "HarnessMonitorDaemon.entitlements"
            write_entitlements(
                entitlements_path,
                {
                    "com.apple.security.files.bookmarks.app-scope": True,
                },
            )

            completed, _, _ = self.run_script(daemon_entitlements=entitlements_path)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn(
            "daemon missing user-selected.read-write",
            completed.stderr,
        )

    def test_rejects_xcodebuild_runner_override(self) -> None:
        completed, runner_args, rtk_args = self.run_script(override_runner=True)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertNotEqual(runner_args, "")
        self.assertEqual(rtk_args, "")


if __name__ == "__main__":
    unittest.main()
