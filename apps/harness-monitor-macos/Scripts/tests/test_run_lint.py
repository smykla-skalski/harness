from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = APP_ROOT / "Scripts" / "run-lint.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class RunLintScriptTests(unittest.TestCase):
    def test_unsets_xcode_only_swift_debug_environment_before_swift_format(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            captured_env_path = temp_root / "captured-swift-env.txt"
            generate_script = temp_root / "generate.sh"
            swift_bin = temp_root / "swift"
            swiftlint_bin = temp_root / "swiftlint"

            write_executable(generate_script, "#!/bin/bash\nset -euo pipefail\n")
            write_executable(
                swift_bin,
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "env | sort > \"$CAPTURED_SWIFT_ENV\"\n",
            )
            write_executable(swiftlint_bin, "#!/bin/bash\nset -euo pipefail\n")

            env = os.environ.copy()
            env.update(
                {
                    "GENERATE_PROJECT_SCRIPT": str(generate_script),
                    "SWIFT_BIN": str(swift_bin),
                    "SWIFTLINT_BIN": str(swiftlint_bin),
                    "SWIFTLINT_CACHE_PATH": str(temp_root / "swiftlint-cache"),
                    "CAPTURED_SWIFT_ENV": str(captured_env_path),
                    "SWIFT_DEBUG_INFORMATION_FORMAT": "dwarf",
                    "SWIFT_DEBUG_INFORMATION_VERSION": "5",
                    "TMPDIR": str(temp_root),
                }
            )

            completed = subprocess.run(
                ["bash", str(SCRIPT_PATH)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            captured_env = captured_env_path.read_text()
            self.assertNotIn("SWIFT_DEBUG_INFORMATION_FORMAT=", captured_env)
            self.assertNotIn("SWIFT_DEBUG_INFORMATION_VERSION=", captured_env)

    def test_reports_lint_failure_explicitly(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            generate_script = temp_root / "generate.sh"
            swift_bin = temp_root / "swift"
            swiftlint_bin = temp_root / "swiftlint"

            write_executable(generate_script, "#!/bin/bash\nset -euo pipefail\n")
            write_executable(
                swift_bin,
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "echo 'swift format failed' >&2\n"
                "exit 64\n",
            )
            write_executable(swiftlint_bin, "#!/bin/bash\nset -euo pipefail\n")

            env = os.environ.copy()
            env.update(
                {
                    "GENERATE_PROJECT_SCRIPT": str(generate_script),
                    "SWIFT_BIN": str(swift_bin),
                    "SWIFTLINT_BIN": str(swiftlint_bin),
                    "SWIFTLINT_CACHE_PATH": str(temp_root / "swiftlint-cache"),
                    "TMPDIR": str(temp_root),
                }
            )

            completed = subprocess.run(
                ["bash", str(SCRIPT_PATH)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(completed.returncode, 64)
            self.assertIn("swift format failed", completed.stderr)
            self.assertIn("[monitor:macos:lint] failed (exit 64)", completed.stderr)
            self.assertIn("monitor:macos lint/quality-gate: failed", completed.stderr)


if __name__ == "__main__":
    unittest.main()
