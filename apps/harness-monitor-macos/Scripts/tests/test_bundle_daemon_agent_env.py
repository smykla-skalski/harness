from __future__ import annotations

import subprocess
import unittest
from pathlib import Path


HELPER_PATH = (
    Path(__file__).resolve().parents[1] / "lib" / "daemon-bundle-env.sh"
)


def run_helper(script: str) -> str:
    command = f"source {HELPER_PATH}; {script}"
    completed = subprocess.run(
        ["bash", "-lc", command],
        check=True,
        capture_output=True,
        text=True,
    )
    return completed.stdout.strip()


class ResolveCargoTargetDirTests(unittest.TestCase):
    def test_uses_explicit_cargo_target_dir_override(self) -> None:
        repo_root = "/tmp/harness"
        explicit_target_dir = "/tmp/shared-cargo-target"

        resolved = run_helper(
            f'repo_root="{repo_root}"; '
            f'export CARGO_TARGET_DIR="{explicit_target_dir}"; '
            "resolve_cargo_target_dir"
        )

        self.assertEqual(resolved, explicit_target_dir)

    def test_defaults_to_shared_repo_target_dir(self) -> None:
        repo_root = "/tmp/harness"

        resolved = run_helper(
            f'repo_root="{repo_root}"; '
            'export TARGET_TEMP_DIR="/tmp/DerivedData/HarnessMonitorUITestHost.build"; '
            "unset CARGO_TARGET_DIR; "
            "resolve_cargo_target_dir"
        )

        self.assertEqual(resolved, f"{repo_root}/target/harness-monitor-xcode-daemon")


if __name__ == "__main__":
    unittest.main()
