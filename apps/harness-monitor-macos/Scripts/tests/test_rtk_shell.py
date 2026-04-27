from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
RTK_SHELL_PATH = APP_ROOT / "Scripts" / "lib" / "rtk-shell.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class RtkShellTests(unittest.TestCase):
    def test_unsets_xcode_only_swift_debug_environment_before_tuist_xcodebuild(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            fake_bin = temp_root / "bin"
            fake_bin.mkdir()
            captured_env_path = temp_root / "captured-tuist-env.txt"
            captured_args_path = temp_root / "captured-tuist-args.txt"
            app_root = temp_root / "HarnessMonitor"
            app_root.mkdir()

            write_executable(
                fake_bin / "tuist",
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "env | sort > \"$CAPTURED_TUIST_ENV\"\n"
                "printf '%s\\n' \"$*\" > \"$CAPTURED_TUIST_ARGS\"\n",
            )

            env = {
                "CAPTURED_TUIST_ENV": str(captured_env_path),
                "CAPTURED_TUIST_ARGS": str(captured_args_path),
                "HARNESS_MONITOR_APP_ROOT": str(app_root),
                "HOME": os.environ.get("HOME", ""),
                "PATH": f"{fake_bin}:/usr/bin:/bin",
                "SWIFT_DEBUG_INFORMATION_FORMAT": "dwarf",
                "SWIFT_DEBUG_INFORMATION_VERSION": "5",
                "TMPDIR": str(temp_root),
            }

            completed = subprocess.run(
                [
                    "bash",
                    "-c",
                    (
                        "unset -f tuist 2>/dev/null || true; "
                        f"source {RTK_SHELL_PATH}; "
                        "run_tuist_xcodebuild_command test-without-building"
                    ),
                ],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(captured_args_path.read_text().strip(), "xcodebuild test-without-building")
            captured_env = captured_env_path.read_text()
            self.assertNotIn("SWIFT_DEBUG_INFORMATION_FORMAT=", captured_env)
            self.assertNotIn("SWIFT_DEBUG_INFORMATION_VERSION=", captured_env)


if __name__ == "__main__":
    unittest.main()
