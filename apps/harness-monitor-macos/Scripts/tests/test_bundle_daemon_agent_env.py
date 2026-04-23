from __future__ import annotations

import subprocess
import tempfile
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

    def test_worktree_defaults_to_common_repo_target_dir(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            repo_root = Path(tmp_dir) / "repo"
            subprocess.run(["git", "init", str(repo_root)], check=True, capture_output=True, text=True)
            subprocess.run(
                ["git", "-C", str(repo_root), "config", "user.name", "Test User"],
                check=True,
                capture_output=True,
                text=True,
            )
            subprocess.run(
                ["git", "-C", str(repo_root), "config", "user.email", "test@example.com"],
                check=True,
                capture_output=True,
                text=True,
            )
            (repo_root / "README.md").write_text("repo\n")
            subprocess.run(
                ["git", "-C", str(repo_root), "add", "README.md"],
                check=True,
                capture_output=True,
                text=True,
            )
            subprocess.run(
                ["git", "-C", str(repo_root), "commit", "-m", "init"],
                check=True,
                capture_output=True,
                text=True,
            )

            worktree_root = repo_root / ".claude" / "worktrees" / "feature"
            worktree_root.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(repo_root),
                    "worktree",
                    "add",
                    str(worktree_root),
                    "-b",
                    "feature",
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            resolved = run_helper(
                f'repo_root="{worktree_root}"; '
                'export TARGET_TEMP_DIR="/tmp/DerivedData/HarnessMonitorUITestHost.build"; '
                "unset CARGO_TARGET_DIR; "
                "resolve_cargo_target_dir"
            )

            self.assertEqual(
                resolved,
                f"{repo_root.resolve()}/target/harness-monitor-xcode-daemon",
            )


if __name__ == "__main__":
    unittest.main()
