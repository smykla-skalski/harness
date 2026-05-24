from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
HELPER_SOURCE = APP_ROOT / "Scripts" / "lib" / "non-indexable-roots.sh"


class NonIndexableRootsTests(unittest.TestCase):
    def run_helper(self, body: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", "-c", f'source "{HELPER_SOURCE}"\n{body}'],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_ensure_non_indexable_directory_creates_marker_idempotently(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir) / "derived"

            completed = self.run_helper(
                f'ensure_non_indexable_directory "{root}"\n'
                f'ensure_non_indexable_directory "{root}"\n'
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertTrue((root / ".metadata_never_index").is_file())

    def test_ensure_monitor_build_artifact_roots_marks_approved_roots(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            repo_root = Path(tmp_dir)

            completed = self.run_helper(
                f'ensure_monitor_build_artifact_roots_non_indexable "{repo_root}"\n'
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            for name in ("xcode-derived", "xcode-derived-e2e", "xcode-derived-instruments"):
                self.assertTrue((repo_root / name / ".metadata_never_index").is_file())


if __name__ == "__main__":
    unittest.main()
