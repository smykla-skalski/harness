from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


HELPER_PATH = (
    Path(__file__).resolve().parents[1] / "lib" / "daemon-bundle-env.sh"
)
CARGO_HELPER_PATH = (
    Path(__file__).resolve().parents[1] / "lib" / "daemon-cargo-build.sh"
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


def run_build_helper(script: str) -> str:
    command = f"source {HELPER_PATH}; source {CARGO_HELPER_PATH}; {script}"
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


class BuildDaemonBinaryTests(unittest.TestCase):
    def test_unsets_xcode_only_swift_debug_environment_before_cargo(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            repo_root = Path(tmp_dir) / "repo"
            project_dir = repo_root / "apps" / "harness-monitor-macos"
            launch_agents_dir = project_dir / "Resources" / "LaunchAgents"
            target_dir = repo_root / "target"
            captured_env_path = Path(tmp_dir) / "captured-env.txt"
            fake_cargo = Path(tmp_dir) / "fake-cargo.sh"

            (repo_root / ".git").mkdir(parents=True)
            launch_agents_dir.mkdir(parents=True, exist_ok=True)
            launch_agents_dir.joinpath("io.harnessmonitor.daemon.Info.plist").write_text(
                """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>io.harnessmonitor.daemon</string>
</dict>
</plist>
"""
            )
            fake_cargo.write_text(
                "#!/bin/bash\n"
                "env | sort > \"$CAPTURED_ENV_PATH\"\n"
            )
            fake_cargo.chmod(0o755)

            run_build_helper(
                f'export PROJECT_DIR="{project_dir}"; '
                f'export CARGO_BIN="{fake_cargo}"; '
                f'export CARGO_TARGET_DIR="{target_dir}"; '
                f'export CAPTURED_ENV_PATH="{captured_env_path}"; '
                'export SWIFT_DEBUG_INFORMATION_FORMAT="dwarf"; '
                'export SWIFT_DEBUG_INFORMATION_VERSION="5"; '
                "build_daemon_binary >/dev/null"
            )

            captured_env = captured_env_path.read_text()
            self.assertNotIn("SWIFT_DEBUG_INFORMATION_FORMAT=", captured_env)
            self.assertNotIn("SWIFT_DEBUG_INFORMATION_VERSION=", captured_env)


if __name__ == "__main__":
    unittest.main()
