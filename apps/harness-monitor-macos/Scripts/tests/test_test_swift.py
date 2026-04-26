from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = APP_ROOT / "Scripts" / "test-swift.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class TestSwiftScriptTests(unittest.TestCase):
    def run_script(
        self,
        *,
        only_testing: str | None = None,
        override_runner: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], list[list[str]], str]:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            app_root = temp_root / "HarnessMonitor"
            scripts_root = app_root / "Scripts"
            scripts_root.mkdir(parents=True)
            derived_data_path = temp_root / "derived"
            run_lint_script = scripts_root / "run-lint.sh"
            build_for_testing_script = scripts_root / "build-for-testing.sh"
            fake_log = temp_root / "log"
            runner_calls = temp_root / "runner-calls.log"
            rtk_calls = temp_root / "rtk-calls.log"

            write_executable(run_lint_script, "#!/bin/bash\nset -euo pipefail\n")
            write_executable(
                build_for_testing_script,
                f"""#!/bin/bash
set -euo pipefail
printf '%s\\n' "build-for-testing" >> "{runner_calls}"
app_dir="${{XCODEBUILD_DERIVED_DATA_PATH}}/Build/Products/Debug/Harness Monitor.app"
mkdir -p "$app_dir"
touch "$app_dir/build-for-testing.marker"
""",
            )
            write_executable(
                fake_log,
                "#!/bin/bash\nset -euo pipefail\n",
            )
            fake_bin = temp_root / "bin"
            fake_bin.mkdir()
            fake_runner = fake_bin / "xcodebuild"
            write_executable(
                fake_runner,
                f"""#!/bin/bash
set -euo pipefail
printf '%s\\n' "$*" >> "{runner_calls}"
app_dir="${{XCODEBUILD_DERIVED_DATA_PATH}}/Build/Products/Debug/Harness Monitor.app"
mkdir -p "$app_dir"
if printf '%s\\n' "$@" | /usr/bin/grep -q 'build-for-testing'; then
  touch "$app_dir/build-for-testing.marker"
fi
""",
            )
            write_executable(fake_log, "#!/bin/bash\nset -euo pipefail\n")
            write_executable(
                fake_bin / "rtk",
                f"""#!/bin/bash
set -euo pipefail
printf '%s\\n' "$*" >> "{rtk_calls}"
exit 1
""",
            )

            env = os.environ.copy()
            env.update(
                {
                    "RUN_LINT_SCRIPT": str(run_lint_script),
                    "BUILD_FOR_TESTING_SCRIPT": str(build_for_testing_script),
                    "HARNESS_MONITOR_APP_ROOT": str(app_root),
                    "XCODEBUILD_DERIVED_DATA_PATH": str(derived_data_path),
                    "LOG_BIN": str(fake_log),
                    "HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE": "1",
                    "PATH": f"{fake_bin}:/usr/bin:/bin",
                    "RTK_BIN": str(fake_bin / "rtk"),
                    "XCODEBUILD_BIN": str(fake_runner),
                    "TMPDIR": str(temp_root),
                }
            )
            if only_testing is not None:
                env["XCODE_ONLY_TESTING"] = only_testing
            if override_runner:
                env["XCODEBUILD_RUNNER"] = str(temp_root / "override-runner.sh")

            completed = subprocess.run(
                ["bash", str(SCRIPT_PATH)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            calls = []
            if runner_calls.exists():
                calls = [line.split() for line in runner_calls.read_text().splitlines() if line]
            rtk_log = rtk_calls.read_text() if rtk_calls.exists() else ""
            return completed, calls, rtk_log

    def test_passes_only_testing_selector_to_test_without_building_invocation(self) -> None:
        completed, calls, rtk_log = self.run_script(
            only_testing="HarnessMonitorKitTests/PolicyGapRuleTests"
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0], ["build-for-testing"])
        self.assertIn("test-without-building", calls[1])
        self.assertIn(
            "-only-testing:HarnessMonitorKitTests/PolicyGapRuleTests",
            calls[1],
        )
        self.assertEqual(rtk_log, "")

    def test_splits_comma_separated_only_testing_selectors(self) -> None:
        completed, calls, rtk_log = self.run_script(
            only_testing=(
                "HarnessMonitorKitTests/PolicyGapRuleTests,"
                "HarnessMonitorUITests/HarnessMonitorUITests/testToolbarOpensSettingsWindow"
            )
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(len(calls), 2)
        self.assertIn("test-without-building", calls[1])
        self.assertIn(
            "-only-testing:HarnessMonitorKitTests/PolicyGapRuleTests",
            calls[1],
        )
        self.assertIn(
            "-only-testing:HarnessMonitorUITests/HarnessMonitorUITests/testToolbarOpensSettingsWindow",
            calls[1],
        )
        self.assertEqual(rtk_log, "")

    def test_rejects_xcodebuild_runner_override(self) -> None:
        completed, calls, rtk_log = self.run_script(override_runner=True)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("XCODEBUILD_RUNNER override is unsupported", completed.stderr)
        self.assertEqual(calls, [])
        self.assertEqual(rtk_log, "")


if __name__ == "__main__":
    unittest.main()
