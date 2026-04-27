from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
BUILD_PHASES_SOURCE = APP_ROOT / "Tuist" / "ProjectDescriptionHelpers" / "BuildPhases.swift"
ENTRY_SCRIPT_SOURCE = APP_ROOT / "Scripts" / "lib" / "xcode-build-phase-entry.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class XcodeBuildPhaseEntryTests(unittest.TestCase):
    def test_build_phases_route_bash_scripts_through_xcode_build_phase_entry(self) -> None:
        source = BUILD_PHASES_SOURCE.read_text()

        self.assertIn(
            '/bin/sh "$SRCROOT/Scripts/lib/xcode-build-phase-entry.sh" "$SRCROOT/Scripts/build-daemon-agent.sh"',
            source,
        )
        self.assertIn(
            '/bin/sh "$PROJECT_DIR/Scripts/lib/xcode-build-phase-entry.sh" "$PROJECT_DIR/Scripts/bundle-daemon-agent.sh"',
            source,
        )
        self.assertIn(
            '/bin/sh "$PROJECT_DIR/Scripts/lib/xcode-build-phase-entry.sh" "$PROJECT_DIR/Scripts/inject-build-provenance.sh" \\(variant.rawValue)',
            source,
        )
        self.assertIn(
            '/bin/sh "$PROJECT_DIR/Scripts/lib/xcode-build-phase-entry.sh" "$PROJECT_DIR/Scripts/strip-test-xattrs.sh"',
            source,
        )
        self.assertNotIn("Helpers/harness.cstemp", source)

    def test_entry_script_unsets_swift_debug_environment_before_bash_starts(self) -> None:
        self.assertTrue(
            ENTRY_SCRIPT_SOURCE.exists(),
            f"Missing build phase entry helper: {ENTRY_SCRIPT_SOURCE}",
        )

        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            entry_script = temp_root / "xcode-build-phase-entry.sh"
            target_script = temp_root / "target.sh"
            captured_env_path = temp_root / "captured-env.txt"

            shutil.copy(ENTRY_SCRIPT_SOURCE, entry_script)
            entry_script.chmod(entry_script.stat().st_mode | stat.S_IXUSR)
            write_executable(
                target_script,
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "env | sort > \"$CAPTURED_ENV\"\n",
            )

            env = os.environ.copy()
            env.update(
                {
                    "CAPTURED_ENV": str(captured_env_path),
                    "SWIFT_DEBUG_INFORMATION_FORMAT": "dwarf",
                    "SWIFT_DEBUG_INFORMATION_VERSION": "5",
                    "TMPDIR": str(temp_root),
                }
            )

            completed = subprocess.run(
                ["/bin/sh", str(entry_script), str(target_script)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(completed.stderr, "")

            captured_env = captured_env_path.read_text()
            self.assertNotIn("SWIFT_DEBUG_INFORMATION_FORMAT=", captured_env)
            self.assertNotIn("SWIFT_DEBUG_INFORMATION_VERSION=", captured_env)


if __name__ == "__main__":
    unittest.main()
