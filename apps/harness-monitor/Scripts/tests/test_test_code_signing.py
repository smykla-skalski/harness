from __future__ import annotations

import os
import subprocess
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = APP_ROOT / "Scripts" / "lib" / "test-code-signing.sh"


class TestCodeSigningTests(unittest.TestCase):
    def resolve(
        self,
        scheme: str,
        only_testing: str = "",
        override: str | None = None,
    ) -> str:
        environment = os.environ.copy()
        if override is None:
            environment.pop("HARNESS_MONITOR_CODE_SIGNING_ALLOWED", None)
        else:
            environment["HARNESS_MONITOR_CODE_SIGNING_ALLOWED"] = override
        completed = subprocess.run(
            [
                "/bin/bash",
                "-c",
                'source "$1"; harness_monitor_test_code_signing_allowed "$2" "$3"',
                "test-code-signing",
                str(SCRIPT_PATH),
                scheme,
                only_testing,
            ],
            check=True,
            capture_output=True,
            text=True,
            env=environment,
        )
        return completed.stdout.strip()

    def test_app_host_schemes_keep_code_signing_enabled(self) -> None:
        for scheme in (
            "HarnessMonitor",
            "HarnessMonitorAppTests",
            "HarnessMonitorUITestHost",
        ):
            with self.subTest(scheme=scheme):
                self.assertEqual(self.resolve(scheme), "YES")

    def test_framework_only_scheme_keeps_unsigned_fast_path(self) -> None:
        self.assertEqual(self.resolve("HarnessMonitorPolicyCanvasTests"), "NO")

    def test_ui_test_selector_requires_signing_on_any_scheme(self) -> None:
        self.assertEqual(
            self.resolve(
                "HarnessMonitorPolicyCanvasTests",
                "HarnessMonitorUITests/HarnessMonitorUITests/testToolbar",
            ),
            "YES",
        )

    def test_explicit_override_wins(self) -> None:
        self.assertEqual(self.resolve("HarnessMonitor", override="NO"), "NO")


if __name__ == "__main__":
    unittest.main()
