from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = APP_ROOT / "Scripts" / "xcodebuild-with-lock.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class XcodebuildWithLockTests(unittest.TestCase):
    def run_script(self, *args: str) -> tuple[subprocess.CompletedProcess[str], str]:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            fake_bin = temp_root / "bin"
            fake_bin.mkdir()
            derived_data_path = temp_root / "derived"
            tool_log = temp_root / "tool.log"

            write_executable(
                fake_bin / "rtk",
                f"""#!/bin/bash
set -euo pipefail
printf 'RTK=%s\\n' "$*" > "{tool_log}"
""",
            )
            write_executable(
                fake_bin / "xcodebuild",
                f"""#!/bin/bash
set -euo pipefail
printf 'XCODEBUILD=%s\\n' "$*" > "{tool_log}"
""",
            )

            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{fake_bin}:/usr/bin:/bin",
                    "RTK_BIN": str(fake_bin / "rtk"),
                    "TMPDIR": str(temp_root),
                }
            )

            completed = subprocess.run(
                [
                    "bash",
                    str(SCRIPT_PATH),
                    "-derivedDataPath",
                    str(derived_data_path),
                    *args,
                ],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            log = tool_log.read_text() if tool_log.exists() else ""
            return completed, log

    def test_prefers_rtk_for_normal_build_invocations(self) -> None:
        completed, log = self.run_script("-scheme", "HarnessMonitor", "build")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("RTK=xcodebuild", log)
        self.assertIn("-scheme HarnessMonitor build", log)

    def test_skips_rtk_for_json_output(self) -> None:
        completed, log = self.run_script("-list", "-json")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("XCODEBUILD=-derivedDataPath", log)
        self.assertIn("-list -json", log)

    def test_skips_rtk_for_show_build_settings(self) -> None:
        completed, log = self.run_script("-showBuildSettings", "-scheme", "HarnessMonitor")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("XCODEBUILD=-derivedDataPath", log)
        self.assertIn("-showBuildSettings -scheme HarnessMonitor", log)


if __name__ == "__main__":
    unittest.main()
