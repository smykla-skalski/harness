from __future__ import annotations

import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = APP_ROOT / "Scripts" / "build-for-testing.sh"
QUALITY_GATE_SCRIPT_PATH = APP_ROOT / "Scripts" / "run-quality-gates.sh"


class BuildForTestingScriptTests(unittest.TestCase):
    def test_defaults_to_skipping_daemon_build_and_bundle(self) -> None:
        script = SCRIPT_PATH.read_text(encoding="utf-8")

        self.assertIn(
            'DAEMON_AGENT_BUILD_SKIP="${HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUILD:-1}"',
            script,
        )
        self.assertIn(
            'DAEMON_AGENT_BUNDLE_SKIP="${HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE:-1}"',
            script,
        )
        self.assertIn(
            'export HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUILD="$DAEMON_AGENT_BUILD_SKIP"',
            script,
        )
        self.assertIn(
            'export HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE="$DAEMON_AGENT_BUNDLE_SKIP"',
            script,
        )
        self.assertIn(
            'HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUILD="$DAEMON_AGENT_BUILD_SKIP"',
            script,
        )
        self.assertIn(
            'HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE="$DAEMON_AGENT_BUNDLE_SKIP"',
            script,
        )

    def test_quality_gate_explicitly_reenables_daemon_validation(self) -> None:
        script = QUALITY_GATE_SCRIPT_PATH.read_text(encoding="utf-8")

        self.assertIn("HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUILD=0", script)
        self.assertIn("HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE=0", script)


if __name__ == "__main__":
    unittest.main()
