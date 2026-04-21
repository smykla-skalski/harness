from __future__ import annotations

import os
import plistlib
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = APP_ROOT / "Scripts" / "run-quality-gates.sh"


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
    ) -> tuple[subprocess.CompletedProcess[str], str]:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            derived_data_path = temp_root / "derived"
            runner_args_log = temp_root / "xcodebuild-args.log"
            generate_project = temp_root / "generate-project.sh"
            fake_runner = temp_root / "xcodebuild-runner.sh"
            fake_log = temp_root / "log"

            write_executable(generate_project, "#!/bin/bash\nset -euo pipefail\n")
            write_executable(
                fake_runner,
                f"""#!/bin/bash
set -euo pipefail
printf '%s\\n' "$@" > "{runner_args_log}"
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
                    "GENERATE_PROJECT_SCRIPT": str(generate_project),
                    "SWIFT_BIN": "/usr/bin/true",
                    "SWIFTLINT_BIN": "/usr/bin/true",
                    "XCODEBUILD_RUNNER": str(fake_runner),
                    "XCODEBUILD_DERIVED_DATA_PATH": str(derived_data_path),
                    "LOG_BIN": str(fake_log),
                    "HARNESS_MONITOR_APP_ENTITLEMENTS_PATH": str(
                        app_entitlements or APP_ROOT / "HarnessMonitor.entitlements"
                    ),
                    "HARNESS_MONITOR_DAEMON_ENTITLEMENTS_PATH": str(
                        daemon_entitlements or APP_ROOT / "HarnessMonitorDaemon.entitlements"
                    ),
                }
            )

            completed = subprocess.run(
                ["bash", str(SCRIPT_PATH)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            args = runner_args_log.read_text() if runner_args_log.exists() else ""
            return completed, args

    def test_build_for_testing_disables_code_signing(self) -> None:
        completed, runner_args = self.run_script()

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("build-for-testing", runner_args)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", runner_args)

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

            completed, _ = self.run_script(app_entitlements=entitlements_path)

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

            completed, _ = self.run_script(daemon_entitlements=entitlements_path)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn(
            "daemon still has temporary-exception entitlement",
            completed.stderr,
        )


if __name__ == "__main__":
    unittest.main()
