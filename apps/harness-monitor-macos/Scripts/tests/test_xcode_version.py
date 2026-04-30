from __future__ import annotations

import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
XCODE_VERSION_HELPER = APP_ROOT / "Scripts" / "lib" / "xcode-version.sh"


def run_helper(command: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    script = f"source {shlex.quote(str(XCODE_VERSION_HELPER))}; {command}"
    return subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )


class XcodeVersionHelperTests(unittest.TestCase):
    def test_reads_dtxcode_from_developer_dir_xcode_app(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            info_plist = temp_root / "Xcode.app" / "Contents" / "Info.plist"
            developer_dir = temp_root / "Xcode.app" / "Contents" / "Developer"
            info_plist.parent.mkdir(parents=True)
            developer_dir.mkdir(parents=True)
            info_plist.write_text(
                """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>DTXcode</key>
  <string>2750</string>
</dict>
</plist>
"""
            )

            env = os.environ.copy()
            env["DEVELOPER_DIR"] = str(developer_dir)
            env.pop("HARNESS_MONITOR_XCODE_DTXCODE", None)

            completed = run_helper("harness_monitor_current_xcode_dtxcode", env)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.strip(), "2750")

    def test_allows_numeric_env_override(self) -> None:
        env = os.environ.copy()
        env["HARNESS_MONITOR_XCODE_DTXCODE"] = "3001"

        completed = run_helper("harness_monitor_current_xcode_dtxcode", env)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.strip(), "3001")

    def test_rejects_non_numeric_env_override(self) -> None:
        env = os.environ.copy()
        env["HARNESS_MONITOR_XCODE_DTXCODE"] = "Xcode"

        completed = run_helper("harness_monitor_current_xcode_dtxcode", env)

        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(completed.stdout, "")


if __name__ == "__main__":
    unittest.main()
