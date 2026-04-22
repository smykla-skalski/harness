from __future__ import annotations

import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "run-instruments-audit.sh"


class RunInstrumentsAuditScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script = SCRIPT_PATH.read_text(encoding="utf-8")

    def test_uses_shared_destination_helper_for_xcodebuild(self) -> None:
        self.assertIn('source "$SCRIPT_DIR/lib/xcodebuild-destination.sh"', self.script)
        self.assertIn('DESTINATION="$(harness_monitor_xcodebuild_destination)"', self.script)
        self.assertIn('-destination "$DESTINATION" \\', self.script)

    def test_launches_staged_app_bundle_directly(self) -> None:
        self.assertIn('--launch -- "$STAGED_HOST_APP_PATH" "$PERSISTENCE_ARG_ONE" "$PERSISTENCE_ARG_TWO"', self.script)
        self.assertNotIn("launch-staged-host", self.script)
        self.assertNotIn("STAGED_HOST_LAUNCHER_PATH", self.script)

    def test_stages_host_bundle_at_stable_path(self) -> None:
        self.assertIn('STAGED_HOST_STAGE_ROOT="$COMMON_REPO_ROOT/tmp/perf/harness-monitor-instruments/staged-host"', self.script)
        self.assertIn('local staged_bundle_name="Harness Monitor UI Testing.app"', self.script)
        self.assertNotIn('Harness Monitor UI Testing ${run_id}.app', self.script)

    def test_staged_host_becomes_agent_app_with_stable_audit_bundle_id(self) -> None:
        self.assertIn('STAGED_HOST_BUNDLE_ID="${HOST_BUNDLE_ID}.audit"', self.script)
        self.assertIn('plist_upsert_bool "$info_plist_path" "LSUIElement" "YES"', self.script)

    def test_purges_legacy_per_run_launch_hosts_before_staging(self) -> None:
        self.assertIn("purge_legacy_launch_hosts() {", self.script)
        self.assertIn("-name 'launch-host' \\", self.script)
        self.assertIn("purge_legacy_launch_hosts", self.script)


if __name__ == "__main__":
    unittest.main()
