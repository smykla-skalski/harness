from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[4]
APP_ROOT = REPO_ROOT / "apps" / "harness-monitor-macos"
SCRIPT_PATH = APP_ROOT / "Scripts" / "test-agents-e2e.sh"


class TestAgentsE2EScriptTests(unittest.TestCase):
    def test_build_for_testing_skips_daemon_bundle_version_check(self) -> None:
        script = SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertIn(
            'HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE=1 "$XCODEBUILD_RUNNER"',
            script,
            "build-for-testing and test-without-building must skip the daemon-bundle gate so the e2e runner does not block on shipping-bundle parity",
        )

    def test_lifecycle_orchestrated_by_swift_e2e_cli(self) -> None:
        script = SCRIPT_PATH.read_text(encoding="utf-8")
        # The Swift CLI owns daemon/bridge/session lifecycle and the data-home
        # contract; HarnessMonitorE2ECoreTests cover the env-var propagation.
        self.assertIn('"$E2E_TOOL_BINARY" "${prepare_args[@]}"', script)
        self.assertIn('"$E2E_TOOL_BINARY" teardown --manifest "$MANIFEST_PATH"', script)

    def test_ui_test_invocations_keep_code_signing_enabled(self) -> None:
        script = SCRIPT_PATH.read_text(encoding="utf-8")

        self.assertIsNone(
            re.search(r"CODE_SIGNING_ALLOWED=NO\s*\\\s*\n\s*build-for-testing", script),
            "build-for-testing must not disable code signing for macOS UI tests",
        )
        self.assertIsNone(
            re.search(r"CODE_SIGNING_ALLOWED=NO\s*\\\s*\n\s*test-without-building", script),
            "test-without-building must not disable code signing for macOS UI tests",
        )

    def test_expensive_e2e_lane_disables_xcodebuild_retries(self) -> None:
        script = SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertIn(
            'HARNESS_MONITOR_TEST_RETRY_ITERATIONS=0',
            script,
            "agents e2e must disable xcodebuild retry iterations so expensive UI runs do not relaunch automatically",
        )

    def test_ui_test_targets_use_apple_development_signing(self) -> None:
        project_swift = (APP_ROOT / "Project.swift").read_text(encoding="utf-8")

        for block_name in ("uiTestsTarget", "agentsE2ETarget"):
            marker = f"private let {block_name}: Target = .target("
            _, separator, tail = project_swift.partition(marker)
            self.assertTrue(separator, f"Missing {block_name} block in Project.swift")
            block = tail.split("\nprivate let ", 1)[0]
            self.assertIn(
                '"CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development"',
                block,
                f"{block_name} must pin Apple Development signing for runnable UI tests",
            )


if __name__ == "__main__":
    unittest.main()
