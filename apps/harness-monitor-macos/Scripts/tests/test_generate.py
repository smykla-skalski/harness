from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
GENERATE_SOURCE = APP_ROOT / "Scripts" / "generate.sh"
SWIFT_TOOL_ENV_SOURCE = APP_ROOT / "Scripts" / "lib" / "swift-tool-env.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class GenerateScriptTests(unittest.TestCase):
    def test_unsets_xcode_only_swift_debug_environment_before_tuist(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            app_root = temp_root / "HarnessMonitor"
            scripts_root = app_root / "Scripts"
            lib_root = scripts_root / "lib"
            tuist_root = app_root / "Tuist"
            generated_script = scripts_root / "generate.sh"
            generated_helper = lib_root / "swift-tool-env.sh"
            fake_post_generate = scripts_root / "post-generate.sh"
            fake_patcher = scripts_root / "patch-tuist-pbxproj.py"
            fake_tuist = temp_root / "fake-tuist.sh"
            captured_env_path = temp_root / "captured-tuist-env.txt"
            captured_args_path = temp_root / "captured-tuist-args.txt"

            lib_root.mkdir(parents=True)
            (tuist_root / ".build").mkdir(parents=True)
            (tuist_root / "Package.swift").write_text("// test\n")
            (app_root / "Project.swift").write_text("// test\n")
            shutil.copy(GENERATE_SOURCE, generated_script)
            generated_script.chmod(generated_script.stat().st_mode | stat.S_IXUSR)
            shutil.copy(SWIFT_TOOL_ENV_SOURCE, generated_helper)
            write_executable(fake_post_generate, "#!/bin/bash\nset -euo pipefail\n")
            fake_patcher.write_text("# test\n")
            write_executable(
                fake_tuist,
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "env | sort > \"$CAPTURED_TUIST_ENV\"\n"
                "printf '%s\\n' \"$*\" > \"$CAPTURED_TUIST_ARGS\"\n",
            )

            env = os.environ.copy()
            env.update(
                {
                    "CAPTURED_TUIST_ENV": str(captured_env_path),
                    "CAPTURED_TUIST_ARGS": str(captured_args_path),
                    "SWIFT_DEBUG_INFORMATION_FORMAT": "dwarf",
                    "SWIFT_DEBUG_INFORMATION_VERSION": "5",
                    "TMPDIR": str(temp_root),
                    "TUIST_BIN": str(fake_tuist),
                }
            )

            completed = subprocess.run(
                ["bash", str(generated_script)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(
                captured_args_path.read_text().strip(),
                f"generate --no-open --path {app_root}",
            )
            captured_env = captured_env_path.read_text()
            self.assertNotIn("SWIFT_DEBUG_INFORMATION_FORMAT=", captured_env)
            self.assertNotIn("SWIFT_DEBUG_INFORMATION_VERSION=", captured_env)


if __name__ == "__main__":
    unittest.main()
