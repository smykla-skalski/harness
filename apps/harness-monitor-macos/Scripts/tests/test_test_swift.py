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
    ) -> tuple[subprocess.CompletedProcess[str], list[list[str]]]:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            derived_data_path = temp_root / "derived"
            generate_project = temp_root / "generate-project.sh"
            fake_runner = temp_root / "xcodebuild-runner.sh"
            fake_log = temp_root / "log"
            runner_calls = temp_root / "runner-calls.log"

            write_executable(generate_project, "#!/bin/bash\nset -euo pipefail\n")
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

            env = os.environ.copy()
            env.update(
                {
                    "GENERATE_PROJECT_SCRIPT": str(generate_project),
                    "SWIFT_BIN": "/usr/bin/true",
                    "SWIFTLINT_BIN": "/usr/bin/true",
                    "XCODEBUILD_RUNNER": str(fake_runner),
                    "XCODEBUILD_DERIVED_DATA_PATH": str(derived_data_path),
                    "LOG_BIN": str(fake_log),
                    "HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE": "1",
                }
            )
            if only_testing is not None:
                env["XCODE_ONLY_TESTING"] = only_testing

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
            return completed, calls

    def test_passes_only_testing_selector_to_test_without_building_invocation(self) -> None:
        completed, calls = self.run_script(
            only_testing="HarnessMonitorKitTests/PolicyGapRuleTests"
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(len(calls), 2)
        self.assertIn("build-for-testing", calls[0])
        self.assertIn("test-without-building", calls[1])
        self.assertIn(
            "-only-testing:HarnessMonitorKitTests/PolicyGapRuleTests",
            calls[1],
        )

    def test_splits_comma_separated_only_testing_selectors(self) -> None:
        completed, calls = self.run_script(
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


if __name__ == "__main__":
    unittest.main()
