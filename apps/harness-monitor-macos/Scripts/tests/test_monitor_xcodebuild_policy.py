from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[4]
APP_ROOT = REPO_ROOT / "apps" / "harness-monitor-macos"
SCRIPT_ROOT = APP_ROOT / "Scripts"
MISE_TOML = REPO_ROOT / ".mise.toml"

ENTRYPOINT_SCRIPTS = (
    SCRIPT_ROOT / "build-for-testing.sh",
    SCRIPT_ROOT / "test-swift.sh",
    SCRIPT_ROOT / "test-agents-e2e.sh",
    SCRIPT_ROOT / "run-instruments-audit.sh",
)


class MonitorXcodebuildPolicyTests(unittest.TestCase):
    def test_monitor_shell_entrypoints_pin_the_lock_aware_runner(self) -> None:
        for script_path in ENTRYPOINT_SCRIPTS:
            script = script_path.read_text(encoding="utf-8")
            self.assertIn(
                'xcodebuild-with-lock.sh',
                script,
                f"{script_path.name} must route monitor xcodebuild traffic through the canonical wrapper",
            )

    def test_monitor_shell_entrypoints_do_not_opt_out_of_tuist(self) -> None:
        for script_path in ENTRYPOINT_SCRIPTS:
            script = script_path.read_text(encoding="utf-8")
            self.assertNotIn(
                "HARNESS_MONITOR_USE_TUIST_TEST=0",
                script,
                f"{script_path.name} must not locally bypass the tuist-first wrapper contract",
            )

    def test_mise_monitor_xcodebuild_task_still_points_at_the_wrapper(self) -> None:
        mise_toml = MISE_TOML.read_text(encoding="utf-8")
        self.assertIn(
            '[tasks."monitor:macos:xcodebuild"]',
            mise_toml,
        )
        self.assertIn(
            'run = "apps/harness-monitor-macos/Scripts/xcodebuild-with-lock.sh"',
            mise_toml,
        )


if __name__ == "__main__":
    unittest.main()
