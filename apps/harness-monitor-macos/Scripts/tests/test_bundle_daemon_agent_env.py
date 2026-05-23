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


def _isolated_subprocess_env() -> dict:
    """Drop BASH_ENV so user `.bash_env` (which runs `mise hook-env`) cannot
    re-scrub the env between when run_daemon_cargo sets RUSTUP_TOOLCHAIN and
    when fake-cargo (bash) reports it. In production cargo runs inside the
    real repo where mise's hook-env re-affirms the pinned toolchain instead
    of stripping it; the test repo lacks `.mise.toml`, so unsetting BASH_ENV
    is the equivalent isolation."""
    import os

    isolated = dict(os.environ)
    isolated.pop("BASH_ENV", None)
    return isolated


def run_helper(script: str) -> str:
    command = f"unset BASH_ENV; source {HELPER_PATH}; {script}"
    completed = subprocess.run(
        ["bash", "-lc", command],
        check=True,
        capture_output=True,
        text=True,
        env=_isolated_subprocess_env(),
    )
    return completed.stdout.strip()


def run_build_helper(script: str) -> str:
    # `unset BASH_ENV` before invoking any child bash (e.g., the test's
    # fake-cargo script). Without this, the child bash sources ~/.bash_env
    # which calls `mise hook-env`; in the test's tmpdir fake repo (no
    # `.mise.toml`), that hook strips RUSTUP_TOOLCHAIN and the assertion that
    # `run_daemon_cargo` exported the pin sees an empty value. In a real
    # build cargo is a native binary, not a bash script, so this path does
    # not exist outside the test harness.
    command = f"unset BASH_ENV; source {HELPER_PATH}; source {CARGO_HELPER_PATH}; {script}"
    completed = subprocess.run(
        ["bash", "-lc", command],
        check=True,
        capture_output=True,
        text=True,
        env=_isolated_subprocess_env(),
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

        self.assertEqual(resolved, f"{repo_root}/.cache/harness-monitor-xcode-daemon")

    def test_replaces_legacy_spotlight_cache_symlink_with_real_cache_root(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            repo_root = Path(tmp_dir) / "repo"
            repo_root.mkdir()
            (repo_root / ".cache").symlink_to(".spotlight-build-artifacts.noindex/.cache")

            resolved = run_helper(
                f'repo_root="{repo_root}"; '
                'export TARGET_TEMP_DIR="/tmp/DerivedData/HarnessMonitorUITestHost.build"; '
                "unset CARGO_TARGET_DIR; "
                "resolve_cargo_target_dir"
            )

            self.assertEqual(resolved, f"{repo_root}/.cache/harness-monitor-xcode-daemon")
            self.assertFalse((repo_root / ".cache").is_symlink())
            self.assertTrue((repo_root / ".cache").is_dir())
            self.assertFalse((repo_root / ".spotlight-build-artifacts.noindex").exists())

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
                f"{repo_root.resolve()}/.cache/harness-monitor-xcode-daemon",
            )


class BuildDaemonBinaryTests(unittest.TestCase):
    def test_unsets_xcode_only_swift_debug_environment_before_cargo(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            project_dir, target_dir, captured_env_path, fake_cargo = _setup_fake_daemon_layout(
                Path(tmp_dir)
            )

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

    def test_strips_rustflags_env_vars_before_cargo(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            project_dir, target_dir, captured_env_path, fake_cargo = _setup_fake_daemon_layout(
                Path(tmp_dir)
            )

            run_build_helper(
                f'export PROJECT_DIR="{project_dir}"; '
                f'export CARGO_BIN="{fake_cargo}"; '
                f'export CARGO_TARGET_DIR="{target_dir}"; '
                f'export CAPTURED_ENV_PATH="{captured_env_path}"; '
                'export RUSTFLAGS="--cfg tokio_unstable --cfg tokio_unstable"; '
                'export CARGO_ENCODED_RUSTFLAGS="--cfg\x1ftokio_unstable"; '
                'export CARGO_BUILD_RUSTFLAGS="--cfg tokio_unstable"; '
                "build_daemon_binary >/dev/null"
            )

            captured_env = captured_env_path.read_text()
            self.assertNotIn("RUSTFLAGS=", captured_env)
            self.assertNotIn("CARGO_ENCODED_RUSTFLAGS=", captured_env)
            self.assertNotIn("CARGO_BUILD_RUSTFLAGS=", captured_env)

    def test_exports_pinned_rustup_toolchain_when_rust_toolchain_file_present(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            project_dir, target_dir, captured_env_path, fake_cargo = _setup_fake_daemon_layout(
                Path(tmp_dir)
            )
            repo_root = project_dir.parent.parent
            (repo_root / "rust-toolchain.toml").write_text(
                '[toolchain]\nchannel = "nightly-2026-05-19"\n'
            )

            run_build_helper(
                f'export PROJECT_DIR="{project_dir}"; '
                f'export CARGO_BIN="{fake_cargo}"; '
                f'export CARGO_TARGET_DIR="{target_dir}"; '
                f'export CAPTURED_ENV_PATH="{captured_env_path}"; '
                # Override the assertion so the test does not require rustup on
                # the test machine; the env-sanitization path is the contract.
                "assert_daemon_cargo_toolchain() { :; }; "
                'export RUSTUP_TOOLCHAIN="some-other-channel"; '
                "build_daemon_binary >/dev/null"
            )

            captured_env = captured_env_path.read_text()
            self.assertIn("RUSTUP_TOOLCHAIN=nightly-2026-05-19", captured_env)

    def test_records_build_context_for_drift_detection(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            project_dir, target_dir, captured_env_path, fake_cargo = _setup_fake_daemon_layout(
                Path(tmp_dir)
            )

            run_build_helper(
                f'export PROJECT_DIR="{project_dir}"; '
                f'export CARGO_BIN="{fake_cargo}"; '
                f'export CARGO_TARGET_DIR="{target_dir}"; '
                f'export CAPTURED_ENV_PATH="{captured_env_path}"; '
                "assert_daemon_cargo_toolchain() { :; }; "
                "build_daemon_binary >/dev/null"
            )

            context_path = target_dir / ".daemon-context"
            self.assertTrue(context_path.is_file())
            self.assertIn(f"cargo={fake_cargo}", context_path.read_text())


class ResolvePinnedToolchainChannelTests(unittest.TestCase):
    def test_returns_empty_when_rust_toolchain_file_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            resolved = run_build_helper(
                f'resolve_pinned_toolchain_channel "{tmp_dir}"'
            )
            self.assertEqual(resolved, "")

    def test_returns_quoted_channel_value(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            (Path(tmp_dir) / "rust-toolchain.toml").write_text(
                '[toolchain]\nchannel = "nightly-2026-05-19"\ncomponents = ["rustfmt"]\n'
            )
            resolved = run_build_helper(
                f'resolve_pinned_toolchain_channel "{tmp_dir}"'
            )
            self.assertEqual(resolved, "nightly-2026-05-19")

    def test_ignores_channel_keys_outside_toolchain_section(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            (Path(tmp_dir) / "rust-toolchain.toml").write_text(
                '[other]\nchannel = "stable"\n\n[toolchain]\nchannel = "nightly-2026-05-19"\n'
            )
            resolved = run_build_helper(
                f'resolve_pinned_toolchain_channel "{tmp_dir}"'
            )
            self.assertEqual(resolved, "nightly-2026-05-19")


class FindCargoTests(unittest.TestCase):
    def test_prefers_rustup_proxy_over_homebrew(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            rustup_cargo = Path(tmp_dir) / ".cargo" / "bin" / "cargo"
            rustup_cargo.parent.mkdir(parents=True)
            rustup_cargo.write_text("#!/bin/bash\necho rustup\n")
            rustup_cargo.chmod(0o755)

            resolved = run_build_helper(
                f'export HOME="{tmp_dir}"; '
                "unset CARGO_BIN; "
                "find_cargo"
            )
            self.assertEqual(resolved, str(rustup_cargo))

    def test_honors_explicit_cargo_bin_override(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            explicit = Path(tmp_dir) / "explicit-cargo"
            explicit.write_text("#!/bin/bash\necho explicit\n")
            explicit.chmod(0o755)

            resolved = run_build_helper(
                f'export CARGO_BIN="{explicit}"; '
                "find_cargo"
            )
            self.assertEqual(resolved, str(explicit))


class CleanActionGuardTests(unittest.TestCase):
    SCRIPTS_DIR = Path(__file__).resolve().parents[1]
    BUILD_SCRIPT = SCRIPTS_DIR / "build-daemon-agent.sh"
    BUNDLE_SCRIPT = SCRIPTS_DIR / "bundle-daemon-agent.sh"

    def _run_with_action(self, script: Path, action: str) -> subprocess.CompletedProcess:
        sentinel_dir = Path(tempfile.mkdtemp(prefix="clean-guard-"))
        cargo_sentinel = sentinel_dir / "cargo-invoked"
        fake_cargo = sentinel_dir / "fake-cargo.sh"
        # Any cargo invocation by the script body would touch this sentinel;
        # the guard contract is that it never runs when ACTION=clean.
        fake_cargo.write_text(f"#!/bin/bash\ntouch {cargo_sentinel}\n")
        fake_cargo.chmod(0o755)
        env = {
            "HOME": tempfile.gettempdir(),
            "PATH": "/usr/bin:/bin",
            "ACTION": action,
            "CARGO_BIN": str(fake_cargo),
            "PROJECT_DIR": str(sentinel_dir),
        }
        completed = subprocess.run(
            ["bash", str(script)],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        return completed, cargo_sentinel

    def test_build_pre_action_no_ops_on_clean(self) -> None:
        completed, sentinel = self._run_with_action(self.BUILD_SCRIPT, "clean")
        self.assertEqual(completed.returncode, 0, msg=completed.stderr)
        self.assertFalse(sentinel.exists(), "cargo must not run on Clean")

    def test_build_pre_action_no_ops_on_clean_build_variant(self) -> None:
        completed, sentinel = self._run_with_action(self.BUILD_SCRIPT, "cleanBuild")
        self.assertEqual(completed.returncode, 0, msg=completed.stderr)
        self.assertFalse(sentinel.exists())

    def test_bundle_phase_no_ops_on_clean(self) -> None:
        completed, sentinel = self._run_with_action(self.BUNDLE_SCRIPT, "clean")
        self.assertEqual(completed.returncode, 0, msg=completed.stderr)
        self.assertFalse(sentinel.exists())


def _setup_fake_daemon_layout(tmp_dir: Path):
    repo_root = tmp_dir / "repo"
    project_dir = repo_root / "apps" / "harness-monitor-macos"
    launch_agents_dir = project_dir / "Resources" / "LaunchAgents"
    target_dir = repo_root / "target"
    captured_env_path = tmp_dir / "captured-env.txt"
    fake_cargo = tmp_dir / "fake-cargo.sh"

    (repo_root / ".git").mkdir(parents=True)
    launch_agents_dir.mkdir(parents=True, exist_ok=True)
    launch_agents_dir.joinpath("io.harnessmonitor.daemon.Info.plist").write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>Q498EB36N4.io.harnessmonitor.daemon</string>
</dict>
</plist>
"""
    )
    fake_cargo.write_text(
        "#!/bin/bash\n"
        "env | sort > \"$CAPTURED_ENV_PATH\"\n"
    )
    fake_cargo.chmod(0o755)
    return project_dir, target_dir, captured_env_path, fake_cargo


if __name__ == "__main__":
    unittest.main()
