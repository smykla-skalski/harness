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
SCRIPT_PATH = Path(__file__).resolve().parents[1] / "bundle-daemon-agent.sh"


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


class BundleDaemonAgentScriptTests(unittest.TestCase):
    def test_main_app_test_actions_do_not_skip_bundling(self) -> None:
        script = SCRIPT_PATH.read_text(encoding="utf-8")

        self.assertNotIn(
            'if [ "${ACTION:-}" = "test" ] || is_test_bundle_target; then',
            script,
        )
        self.assertIn("if is_test_bundle_target; then", script)


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

    def test_recorded_context_uses_pinned_channel_not_shell_env(self) -> None:
        # Regression: previously the drift detector recorded
        # `RUSTUP_TOOLCHAIN=${RUSTUP_TOOLCHAIN:-}` (the script's shell env).
        # Xcode UI has no mise activation, so the shell env had an empty
        # value, while a terminal run had the pinned channel. The detector
        # then reported false drift every time. Must record the effective
        # value that cargo will see, i.e. the pinned channel.
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
                "assert_daemon_cargo_toolchain() { :; }; "
                # Two runs with different shell-side RUSTUP_TOOLCHAIN values
                # must produce identical .daemon-context (same pin).
                'export RUSTUP_TOOLCHAIN=""; '
                "build_daemon_binary >/dev/null"
            )
            first = (target_dir / ".daemon-context").read_text()

            run_build_helper(
                f'export PROJECT_DIR="{project_dir}"; '
                f'export CARGO_BIN="{fake_cargo}"; '
                f'export CARGO_TARGET_DIR="{target_dir}"; '
                f'export CAPTURED_ENV_PATH="{captured_env_path}"; '
                "assert_daemon_cargo_toolchain() { :; }; "
                'export RUSTUP_TOOLCHAIN="some-other-channel"; '
                "build_daemon_binary >/dev/null"
            )
            second = (target_dir / ".daemon-context").read_text()

            self.assertEqual(first, second)
            self.assertIn("RUSTUP_TOOLCHAIN=nightly-2026-05-19", first)


class DaemonStagedBinaryTests(unittest.TestCase):
    def test_staged_binary_path_is_worktree_specific(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            repo_root = Path(tmp_dir) / "repo"
            worktree_root = Path(tmp_dir) / "repo-worktree"
            target_dir = Path(tmp_dir) / "target"
            repo_root.mkdir()
            worktree_root.mkdir()

            main_path = run_build_helper(
                f'repo_root="{repo_root}"; '
                f'export CARGO_TARGET_DIR="{target_dir}"; '
                "daemon_staged_binary_path"
            )
            worktree_path = run_build_helper(
                f'repo_root="{worktree_root}"; '
                f'export CARGO_TARGET_DIR="{target_dir}"; '
                "daemon_staged_binary_path"
            )

            self.assertNotEqual(main_path, worktree_path)
            self.assertTrue(main_path.endswith("/debug/harness"))
            self.assertTrue(worktree_path.endswith("/debug/harness"))

    def test_stage_daemon_binary_copies_executable_to_stage_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            project_dir, target_dir, _, _ = _setup_fake_daemon_layout(Path(tmp_dir))
            source_binary = target_dir / "debug" / "harness"
            source_binary.parent.mkdir(parents=True, exist_ok=True)
            source_binary.write_text("binary\n")
            source_binary.chmod(0o755)

            staged_binary = run_build_helper(
                f'export PROJECT_DIR="{project_dir}"; '
                f'export CARGO_TARGET_DIR="{target_dir}"; '
                f'stage_daemon_binary "{source_binary}"'
            )

            staged_path = Path(staged_binary)
            self.assertTrue(staged_path.is_file())
            self.assertEqual(staged_path.read_text(), "binary\n")
            self.assertTrue(staged_path.stat().st_mode & 0o111)
            self.assertTrue(Path(f"{staged_binary}.inputs").is_file())

    def test_bundle_resolution_reuses_fresh_staged_binary_without_cargo(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            project_dir, target_dir, captured_env_path, fake_cargo = _setup_fake_daemon_layout(
                Path(tmp_dir)
            )
            source_binary = target_dir / "debug" / "harness"
            source_binary.parent.mkdir(parents=True, exist_ok=True)
            source_binary.write_text("staged\n")
            source_binary.chmod(0o755)
            staged_binary = run_build_helper(
                f'export PROJECT_DIR="{project_dir}"; '
                f'export CARGO_TARGET_DIR="{target_dir}"; '
                f'stage_daemon_binary "{source_binary}"'
            )

            resolved_binary = run_build_helper(
                f'export PROJECT_DIR="{project_dir}"; '
                f'export CARGO_BIN="{fake_cargo}"; '
                f'export CARGO_TARGET_DIR="{target_dir}"; '
                f'export CAPTURED_ENV_PATH="{captured_env_path}"; '
                "resolve_daemon_binary_for_bundle"
            )

            self.assertEqual(resolved_binary, staged_binary)
            self.assertFalse(captured_env_path.exists(), "cargo must not run when staged binary is fresh")

    def test_bundle_resolution_builds_and_stages_when_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            project_dir, target_dir, captured_env_path, fake_cargo = _setup_fake_daemon_layout(
                Path(tmp_dir)
            )

            resolved_binary = run_build_helper(
                f'export PROJECT_DIR="{project_dir}"; '
                f'export CARGO_BIN="{fake_cargo}"; '
                f'export CARGO_TARGET_DIR="{target_dir}"; '
                f'export CAPTURED_ENV_PATH="{captured_env_path}"; '
                "resolve_daemon_binary_for_bundle"
            )

            self.assertTrue(Path(resolved_binary).is_file())
            self.assertTrue(captured_env_path.is_file(), "cargo must run when staged binary is missing")

    def test_git_backed_freshness_detects_modified_rust_input(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            repo_root = Path(tmp_dir) / "repo"
            project_dir = repo_root / "apps" / "harness-monitor"
            target_dir = Path(tmp_dir) / "target"
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

            (repo_root / "Cargo.toml").write_text("[package]\nname = \"harness\"\nversion = \"1.2.3\"\n")
            (repo_root / "Cargo.lock").write_text("")
            (repo_root / "build.rs").write_text("fn main() {}\n")
            (repo_root / "rust-toolchain.toml").write_text('[toolchain]\nchannel = "stable"\n')
            (repo_root / ".cargo").mkdir()
            (repo_root / ".cargo" / "config.toml").write_text("")
            (repo_root / "scripts").mkdir()
            (repo_root / "scripts" / "rustc-cache-wrapper.sh").write_text("#!/bin/bash\n")
            (repo_root / "src").mkdir()
            rust_source = repo_root / "src" / "main.rs"
            rust_source.write_text("fn main() {}\n")
            project_dir.mkdir(parents=True)

            subprocess.run(
                [
                    "git",
                    "-C",
                    str(repo_root),
                    "add",
                    "Cargo.toml",
                    "Cargo.lock",
                    "build.rs",
                    "rust-toolchain.toml",
                    ".cargo/config.toml",
                    "scripts/rustc-cache-wrapper.sh",
                    "src/main.rs",
                ],
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

            source_binary = target_dir / "debug" / "harness"
            source_binary.parent.mkdir(parents=True, exist_ok=True)
            source_binary.write_text("binary\n")
            source_binary.chmod(0o755)

            staged_binary = run_build_helper(
                f'export PROJECT_DIR="{project_dir}"; '
                f'export CARGO_TARGET_DIR="{target_dir}"; '
                f'stage_daemon_binary "{source_binary}"'
            )
            fresh_before = run_build_helper(
                f'export PROJECT_DIR="{project_dir}"; '
                f'export CARGO_TARGET_DIR="{target_dir}"; '
                f'daemon_staged_binary_is_fresh "{staged_binary}" && printf yes || printf no'
            )
            self.assertEqual(fresh_before, "yes")

            rust_source.write_text("fn main() { println!(\"changed\"); }\n")
            fresh_after = run_build_helper(
                f'export PROJECT_DIR="{project_dir}"; '
                f'export CARGO_TARGET_DIR="{target_dir}"; '
                f'daemon_staged_binary_is_fresh "{staged_binary}" && printf yes || printf no'
            )
            self.assertEqual(fresh_after, "no")


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
    def test_returns_rustup_proxy(self) -> None:
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


class AssertNoStandaloneRustTests(unittest.TestCase):
    def test_passes_when_no_stray_paths_exist(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            missing_a = Path(tmp_dir) / "does-not-exist-rustc"
            missing_b = Path(tmp_dir) / "does-not-exist-cargo"
            # Function exits 0 (silent) when no path exists.
            run_build_helper(
                f'assert_no_standalone_rust "{missing_a}" "{missing_b}"'
            )

    def test_fails_when_stray_rustc_exists(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            stray = Path(tmp_dir) / "stray-rustc"
            stray.write_text("#!/bin/bash\necho stray\n")
            stray.chmod(0o755)

            command = (
                f"unset BASH_ENV; source {HELPER_PATH}; "
                f"source {CARGO_HELPER_PATH}; "
                f'assert_no_standalone_rust "{stray}"'
            )
            completed = subprocess.run(
                ["bash", "-lc", command],
                capture_output=True,
                text=True,
                env=_isolated_subprocess_env(),
            )
            self.assertNotEqual(
                completed.returncode, 0, msg=completed.stdout
            )
            self.assertIn(
                "shadows the rustup proxy", completed.stderr
            )
            self.assertIn(str(stray), completed.stderr)

    def test_fails_when_any_of_multiple_paths_exists(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            missing = Path(tmp_dir) / "missing"
            present = Path(tmp_dir) / "present"
            present.write_text("#!/bin/bash\n")
            present.chmod(0o755)

            command = (
                f"unset BASH_ENV; source {HELPER_PATH}; "
                f"source {CARGO_HELPER_PATH}; "
                f'assert_no_standalone_rust "{missing}" "{present}"'
            )
            completed = subprocess.run(
                ["bash", "-lc", command],
                capture_output=True,
                text=True,
                env=_isolated_subprocess_env(),
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn(str(present), completed.stderr)
            self.assertNotIn(str(missing), completed.stderr)


class FindCargoGuardListTests(unittest.TestCase):
    """Structural assertions on the hardcoded probe list inside find_cargo.

    The function passes a fixed set of paths to assert_no_standalone_rust;
    those paths are not configurable from outside, so the only way to verify
    each canonical location is covered is by reading the source.
    """

    def test_probes_homebrew_macports_and_usr_local_paths(self) -> None:
        source = CARGO_HELPER_PATH.read_text()
        expected = [
            "/opt/homebrew/bin/rustc",
            "/opt/homebrew/bin/cargo",
            "/usr/local/bin/rustc",
            "/usr/local/bin/cargo",
            "/opt/local/bin/rustc",
            "/opt/local/bin/cargo",
        ]
        for path in expected:
            self.assertIn(
                path,
                source,
                msg=f"find_cargo guard is missing probe for {path}",
            )


class RunDaemonCargoTests(unittest.TestCase):
    # Inner /bin/bash command is single-quoted so the OUTER bash (where
    # run_daemon_cargo is sourced) does not expand $PATH before env injects
    # the prepended value. Inner bash receives `printf %s "$PATH"` verbatim
    # and the assertion sees what env actually exported.
    _PRINT_INNER_PATH = "/bin/bash -c 'printf %s \"$PATH\"'"

    def test_prepends_cargo_bin_to_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            home = Path(tmp_dir)
            (home / ".cargo" / "bin").mkdir(parents=True)
            output = run_build_helper(
                f'export HOME="{home}"; '
                'export PATH="/usr/bin:/bin"; '
                f'run_daemon_cargo "" {self._PRINT_INNER_PATH}'
            )
            self.assertTrue(
                output.startswith(f"{home}/.cargo/bin:"),
                msg=f"PATH did not begin with cargo bin: {output!r}",
            )

    def test_skips_path_prepend_when_cargo_bin_absent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            home = Path(tmp_dir)
            # Intentionally do NOT create ~/.cargo/bin
            output = run_build_helper(
                f'export HOME="{home}"; '
                'export PATH="/usr/bin:/bin"; '
                f'run_daemon_cargo "" {self._PRINT_INNER_PATH}'
            )
            self.assertEqual(output, "/usr/bin:/bin")


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


class BundleStampShortcutTests(unittest.TestCase):
    SCRIPTS_DIR = Path(__file__).resolve().parents[1]
    BUNDLE_SCRIPT = SCRIPTS_DIR / "bundle-daemon-agent.sh"

    def test_matching_stamp_exits_before_bundle_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            repo_root = root / "repo"
            project_dir = repo_root / "apps" / "harness-monitor"
            target_build_dir = root / "build"
            derived_dir = root / "derived"
            daemon_source = root / "daemon-source"
            daemon_target = target_build_dir / "Contents" / "Helpers" / "harness"
            plist_target = (
                target_build_dir
                / "Contents"
                / "Library"
                / "LaunchAgents"
                / "Q498EB36N4.io.harnessmonitor.daemon.plist"
            )
            bundle_stamp_path = derived_dir / "HarnessMonitor-bundle-daemon-agent.stamp"

            (repo_root / ".git").mkdir(parents=True)
            project_dir.mkdir(parents=True, exist_ok=True)
            daemon_target.parent.mkdir(parents=True, exist_ok=True)
            plist_target.parent.mkdir(parents=True, exist_ok=True)
            derived_dir.mkdir(parents=True, exist_ok=True)

            daemon_source.write_text("#!/bin/bash\nexit 0\n")
            daemon_source.chmod(0o755)
            daemon_target.write_text("bundled\n")
            daemon_target.chmod(0o755)
            plist_target.write_text("plist\n")

            daemon_stat = daemon_source.stat()
            stamp_lines = [
                f"daemon_source={daemon_source}",
                f"daemon_source_stat={int(daemon_stat.st_mtime)}:{daemon_stat.st_size}",
                "codesign_identity=fake-identity",
                "timestamp_flag=--timestamp=none",
                "launch_agent_label=Q498EB36N4.io.harnessmonitor.daemon",
                "app_group_id=test.group",
                "marketing_version=1.2.3",
                "daemon_data_home=/tmp/test-daemon-home",
                "codex_ws_port=4242",
                "runtime_lane=test-lane",
                "daemon_plist_sha=missing",
                "legacy_managed_plist_sha=missing",
                "legacy_plist_sha=missing",
                "entitlements_sha=missing",
            ]
            bundle_stamp_path.write_text("\n".join(stamp_lines) + "\n")

            env = {
                "HOME": tempfile.gettempdir(),
                "PATH": "/usr/bin:/bin",
                "PROJECT_DIR": str(project_dir),
                "TARGET_BUILD_DIR": str(target_build_dir),
                "CONTENTS_FOLDER_PATH": "Contents",
                "DERIVED_FILE_DIR": str(derived_dir),
                "TARGET_NAME": "HarnessMonitor",
                "HARNESS_MONITOR_DAEMON_BINARY": str(daemon_source),
                "HARNESS_MONITOR_RUNTIME_LANE": "test-lane",
                "HARNESS_DAEMON_DATA_HOME": "/tmp/test-daemon-home",
                "HARNESS_CODEX_WS_PORT": "4242",
                "HARNESS_APP_GROUP_ID": "test.group",
                "EXPANDED_CODE_SIGN_IDENTITY": "fake-identity",
                "MARKETING_VERSION": "1.2.3",
            }
            completed = subprocess.run(
                ["bash", str(self.BUNDLE_SCRIPT)],
                env=env,
                capture_output=True,
                text=True,
                timeout=10,
            )

            self.assertEqual(completed.returncode, 0, msg=completed.stderr)


def _setup_fake_daemon_layout(tmp_dir: Path):
    repo_root = tmp_dir / "repo"
    project_dir = repo_root / "apps" / "harness-monitor"
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
        "profile_dir=debug\n"
        "for arg in \"$@\"; do\n"
        "  if [ \"$arg\" = \"--release\" ]; then\n"
        "    profile_dir=release\n"
        "  fi\n"
        "done\n"
        "mkdir -p \"$CARGO_TARGET_DIR/$profile_dir\"\n"
        "printf 'fake daemon\\n' > \"$CARGO_TARGET_DIR/$profile_dir/harness\"\n"
        "chmod 755 \"$CARGO_TARGET_DIR/$profile_dir/harness\"\n"
        "env | sort > \"$CAPTURED_ENV_PATH\"\n"
    )
    fake_cargo.chmod(0o755)
    return project_dir, target_dir, captured_env_path, fake_cargo


if __name__ == "__main__":
    unittest.main()
