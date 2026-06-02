from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[4]
APP_ROOT = REPO_ROOT / "apps" / "harness-monitor"
SCRIPT_ROOT = APP_ROOT / "Scripts"
MISE_TOML = REPO_ROOT / ".mise.toml"

ENTRYPOINT_SCRIPTS = (
    SCRIPT_ROOT / "build-for-testing.sh",
    SCRIPT_ROOT / "test-swift.sh",
    SCRIPT_ROOT / "test-agents-e2e.sh",
    SCRIPT_ROOT / "run-instruments-audit.sh",
)


class MonitorXcodebuildPolicyTests(unittest.TestCase):
    def test_monitor_shell_entrypoints_pin_the_lane_runner(self) -> None:
        for script_path in ENTRYPOINT_SCRIPTS:
            script = script_path.read_text(encoding="utf-8")
            self.assertIn(
                'monitor-xcodebuild.sh',
                script,
                f"{script_path.name} must route monitor xcodebuild traffic through the canonical lane wrapper",
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
            '[tasks."monitor:xcodebuild"]',
            mise_toml,
        )
        self.assertIn(
            'run = "apps/harness-monitor/Scripts/monitor-xcodebuild.sh"',
            mise_toml,
        )

    def test_mise_monitor_policy_lab_task_uses_the_fixed_user_lane(self) -> None:
        mise_toml = MISE_TOML.read_text(encoding="utf-8")
        task_match = re.search(
            r'^\[tasks\."monitor:policy-lab"\]\n(?P<body>.*?)(?=^\[tasks\.|\Z)',
            mise_toml,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(task_match)
        assert task_match is not None
        task_body = task_match.group("body")
        self.assertIn("HARNESS_MONITOR_BUILD_LANE=user", task_body)
        self.assertIn("HARNESS_MONITOR_RUNTIME_LANE=user", task_body)
        self.assertIn("HARNESS_MONITOR_POLICY_LAB_GENERATE=1", task_body)
        self.assertIn(
            "apps/harness-monitor/Scripts/policy-canvas-lab-capture.sh",
            task_body,
        )

    def test_policy_canvas_lab_capture_uses_the_standalone_lab_host(self) -> None:
        script = (SCRIPT_ROOT / "policy-canvas-lab-capture.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn('-scheme HarnessMonitorPolicyCanvasLab', script)
        self.assertIn('Harness Monitor Policy Canvas Lab.app', script)
        self.assertNotIn('HarnessMonitorIsolated', script)
        self.assertNotIn('HARNESS_MONITOR_POLICY_CANVAS_LAB=1', script)


if __name__ == "__main__":
    unittest.main()
