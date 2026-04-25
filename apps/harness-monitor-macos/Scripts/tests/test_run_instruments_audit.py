from __future__ import annotations

import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "run-instruments-audit.sh"
FROM_REF_SCRIPT_PATH = Path(__file__).resolve().parents[1] / "run-instruments-audit-from-ref.sh"


class RunInstrumentsAuditScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script = SCRIPT_PATH.read_text(encoding="utf-8")

    def test_uses_shared_destination_helper_for_xcodebuild(self) -> None:
        self.assertIn('source "$SCRIPT_DIR/lib/xcodebuild-destination.sh"', self.script)
        self.assertIn('DESTINATION="$(harness_monitor_xcodebuild_destination)"', self.script)

    def test_audit_dispatches_to_swift_cli(self) -> None:
        self.assertIn('"$PERF_CLI_BINARY" audit "${audit_args[@]}" "$@"', self.script)
        self.assertIn('--app-root "$APP_ROOT"', self.script)
        self.assertIn('--checkout-root "$CHECKOUT_ROOT"', self.script)
        self.assertIn('--common-repo-root "$COMMON_REPO_ROOT"', self.script)
        self.assertIn('--xcodebuild-runner "$XCODEBUILD_RUNNER"', self.script)
        self.assertIn('--destination "$DESTINATION"', self.script)
        self.assertIn('--derived-data-path "$DERIVED_DATA_PATH"', self.script)
        self.assertIn('--runs-root "$RUNS_ROOT"', self.script)
        self.assertIn('--staged-host-root "$STAGED_HOST_ROOT"', self.script)
        self.assertIn('--daemon-cargo-target-dir "$DAEMON_CARGO_TARGET_DIR"', self.script)
        self.assertIn('--arch "$ARCH"', self.script)

    def test_audit_pipeline_helpers_no_longer_live_in_shell(self) -> None:
        # The Swift AuditRunner owns build/staging/capture/manifest now.
        # Shell wrapper only resolves paths and execs the perf CLI.
        self.assertNotIn("acquire_audit_lock", self.script)
        self.assertNotIn("purge_legacy_launch_hosts", self.script)
        self.assertNotIn("plist_upsert_bool", self.script)
        self.assertNotIn("xcrun xctrace record", self.script)


class RunInstrumentsAuditFromRefScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script = FROM_REF_SCRIPT_PATH.read_text(encoding="utf-8")

    def test_dispatches_to_swift_cli_audit_from_ref(self) -> None:
        self.assertIn('"${cmd[@]}"', self.script)
        self.assertIn('"$PERF_CLI_BINARY" audit-from-ref', self.script)
        self.assertIn('--ref "$ref"', self.script)
        self.assertIn('--label "$audit_label"', self.script)
        self.assertIn('--checkout-root "$CHECKOUT_ROOT"', self.script)
        self.assertIn('--worktree-root "$worktree_root"', self.script)


if __name__ == "__main__":
    unittest.main()
