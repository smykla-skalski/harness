from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
HELPER_PATH = APP_ROOT / "Scripts" / "lib" / "runtime-profile.sh"
USER_PROFILE_SCRIPT = APP_ROOT / "Scripts" / "user-runtime-profile.sh"
COMMON_REPO_ROOT_SOURCE = APP_ROOT.parents[1] / "scripts" / "lib" / "common-repo-root.sh"
DEFAULT_APP_GROUP_ID = "Q498EB36N4.io.harnessmonitor"
AGENT_SESSION_ENV_KEYS = (
    "HARNESS_AGENT_ID",
    "CODEX_SESSION_ID",
    "CODEX_THREAD_ID",
    "CLAUDE_SESSION_ID",
    "GEMINI_SESSION_ID",
    "COPILOT_SESSION_ID",
    "OPENCODE_SESSION_ID",
    "VIBE_SESSION_ID",
)


def run_helper(script: str, env: dict[str, str]) -> str:
    completed = subprocess.run(
        ["bash", "-lc", f"source {HELPER_PATH}; {script}"],
        check=True,
        capture_output=True,
        text=True,
        env=env,
    )
    return completed.stdout.strip()


def run_helper_result(script: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-lc", f"source {HELPER_PATH}; {script}"],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )


def expected_profile_port(profile: str) -> str:
    digest_prefix = hashlib.sha256(profile.encode("utf-8")).hexdigest()[:8]
    return str(4600 + (int(digest_prefix, 16) % 20000))


def base_env() -> dict[str, str]:
    env = os.environ.copy()
    for key in AGENT_SESSION_ENV_KEYS:
        env.pop(key, None)
    env.pop("HARNESS_MONITOR_ALLOW_NON_AGENT_RUNTIME_PROFILE", None)
    env.pop("HARNESS_MONITOR_ALLOW_AGENT_USER_PROFILE", None)
    return env


class RuntimeProfileHelperTests(unittest.TestCase):
    def test_profile_env_resolves_profiled_paths_port_and_label(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            home_dir = Path(tmp_dir) / "home"
            home_dir.mkdir()
            env = base_env()
            env.update(
                {
                    "HOME": str(home_dir),
                    "HARNESS_MONITOR_RUNTIME_PROFILE": "Bart Dev",
                }
            )

            output = run_helper(
                "printf '%s\\n%s\\n%s\\n%s\\n%s\\n' "
                '"$(harness_monitor_runtime_profile)" '
                '"$(harness_monitor_runtime_derived_data_path /repo-common)" '
                '"$(harness_monitor_runtime_daemon_data_home)" '
                '"$(harness_monitor_runtime_codex_ws_port)" '
                '"$(harness_monitor_runtime_launch_agent_label)"',
                env,
            )
            profile, derived_data_path, daemon_data_home, codex_port, label = (
                output.splitlines()
            )

            self.assertEqual(profile, "bart-dev")
            self.assertEqual(
                derived_data_path,
                "/repo-common/xcode-derived/profiles/bart-dev",
            )
            self.assertEqual(
                daemon_data_home,
                str(
                    home_dir
                    / "Library"
                    / "Group Containers"
                    / DEFAULT_APP_GROUP_ID
                    / "runtime-profiles"
                    / "bart-dev"
                ),
            )
            self.assertEqual(codex_port, expected_profile_port("bart-dev"))
            self.assertEqual(label, "io.harnessmonitor.daemon.bart-dev")

    def test_apply_runtime_profile_environment_can_infer_profile_from_derived_data_path(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            home_dir = Path(tmp_dir) / "home"
            home_dir.mkdir()
            env = base_env()
            env.update(
                {
                    "HOME": str(home_dir),
                    "XCODEBUILD_DERIVED_DATA_PATH": "/tmp/xcode-derived/profiles/My Profile",
                }
            )

            output = run_helper(
                "unset HARNESS_MONITOR_RUNTIME_PROFILE HARNESS_DAEMON_DATA_HOME "
                "HARNESS_CODEX_WS_PORT HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL; "
                "harness_monitor_apply_runtime_profile_environment; "
                "printf '%s\\n%s\\n%s\\n%s\\n' "
                '"$HARNESS_MONITOR_RUNTIME_PROFILE" '
                '"$HARNESS_DAEMON_DATA_HOME" '
                '"$HARNESS_CODEX_WS_PORT" '
                '"$HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL"',
                env,
            )
            profile, daemon_data_home, codex_port, label = output.splitlines()

            self.assertEqual(profile, "my-profile")
            self.assertEqual(
                daemon_data_home,
                str(
                    home_dir
                    / "Library"
                    / "Group Containers"
                    / DEFAULT_APP_GROUP_ID
                    / "runtime-profiles"
                    / "my-profile"
                ),
            )
            self.assertEqual(codex_port, expected_profile_port("my-profile"))
            self.assertEqual(label, "io.harnessmonitor.daemon.my-profile")

    def test_default_user_profile_collapses_email_local_part(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            env = base_env()
            env.update(
                {
                    "HOME": str(Path(tmp_dir) / "home"),
                    "USER": "bart.smykla@konghq.com",
                }
            )

            output = run_helper("harness_monitor_default_user_runtime_profile", env)

            self.assertEqual(output, "bartsmykla")

    def test_default_agent_profile_uses_agent_session_id(self) -> None:
        env = base_env()
        env["CODEX_SESSION_ID"] = "sess-agent-123"

        output = run_helper("harness_monitor_default_agent_runtime_profile", env)

        self.assertEqual(output, "agent-sess-agent-123")

    def test_runtime_profile_defaults_to_agent_session_profile_when_unset(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            home_dir = Path(tmp_dir) / "home"
            home_dir.mkdir()
            env = base_env()
            env.update(
                {
                    "HOME": str(home_dir),
                    "CODEX_SESSION_ID": "sess-agent-123",
                }
            )

            output = run_helper(
                "printf '%s\\n%s\\n%s\\n' "
                '"$(harness_monitor_runtime_profile)" '
                '"$(harness_monitor_runtime_derived_data_path /repo-common)" '
                '"$(harness_monitor_runtime_launch_agent_label)"',
                env,
            )
            profile, derived_data_path, label = output.splitlines()

            self.assertEqual(profile, "agent-sess-agent-123")
            self.assertEqual(
                derived_data_path,
                "/repo-common/xcode-derived/profiles/agent-sess-agent-123",
            )
            self.assertEqual(label, "io.harnessmonitor.daemon.agent-sess-agent-123")

    def test_runtime_profile_rejects_path_derived_non_agent_profile_in_agent_session(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            home_dir = Path(tmp_dir) / "home"
            home_dir.mkdir(parents=True)

            cases = (
                ("XCODEBUILD_DERIVED_DATA_PATH", "/tmp/xcode-derived/profiles/Bart Dev"),
                (
                    "HARNESS_DAEMON_DATA_HOME",
                    str(
                        home_dir
                        / "Library"
                        / "Group Containers"
                        / DEFAULT_APP_GROUP_ID
                        / "runtime-profiles"
                        / "Bart Dev"
                    ),
                ),
            )

            for env_key, env_value in cases:
                with self.subTest(env_key=env_key):
                    env = base_env()
                    env.update(
                        {
                            "HOME": str(home_dir),
                            "CODEX_SESSION_ID": "sess-agent-123",
                            env_key: env_value,
                        }
                    )

                    completed = run_helper_result("harness_monitor_runtime_profile", env)

                    self.assertNotEqual(completed.returncode, 0)
                    self.assertIn(
                        "Agent sessions must use an isolated agent-* runtime profile",
                        completed.stderr,
                    )

    def test_runtime_profile_allows_non_agent_override_when_opted_in(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            home_dir = Path(tmp_dir) / "home"
            home_dir.mkdir()
            env = base_env()
            env.update(
                {
                    "HOME": str(home_dir),
                    "CODEX_SESSION_ID": "sess-agent-123",
                    "HARNESS_MONITOR_RUNTIME_PROFILE": "Bart Dev",
                    "HARNESS_MONITOR_ALLOW_NON_AGENT_RUNTIME_PROFILE": "1",
                }
            )

            output = run_helper("harness_monitor_runtime_profile", env)

            self.assertEqual(output, "bart-dev")

    def test_user_runtime_profile_script_prints_profile_details(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            home_dir = Path(tmp_dir) / "home"
            home_dir.mkdir()
            repo_root = Path(tmp_dir) / "repo"
            app_root = repo_root / "apps" / "harness-monitor-macos"
            scripts_root = app_root / "Scripts"
            lib_root = scripts_root / "lib"
            workspace_roots = (
                app_root / "HarnessMonitor.xcworkspace",
                app_root / "HarnessMonitor.xcodeproj" / "project.xcworkspace",
            )
            lib_root.mkdir(parents=True)
            for workspace_root in workspace_roots:
                workspace_root.mkdir(parents=True)
            shutil.copy(USER_PROFILE_SCRIPT, scripts_root / "user-runtime-profile.sh")
            shutil.copy(HELPER_PATH, lib_root / "runtime-profile.sh")
            common_repo_root_destination = repo_root / "scripts" / "lib"
            common_repo_root_destination.mkdir(parents=True)
            shutil.copy(
                COMMON_REPO_ROOT_SOURCE,
                common_repo_root_destination / "common-repo-root.sh",
            )
            env = base_env()
            env.update(
                {
                    "HOME": str(home_dir),
                    "HARNESS_MONITOR_USER_RUNTIME_PROFILE": "Bart Dev",
                    "USER": "bart.smykla@konghq.com",
                }
            )

            completed = subprocess.run(
                ["bash", str(scripts_root / "user-runtime-profile.sh")],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("Harness Monitor user profile: bart-dev", completed.stdout)
            self.assertIn("DerivedData:", completed.stdout)
            self.assertIn("Daemon data home:", completed.stdout)
            self.assertIn("Codex WS port:", completed.stdout)
            self.assertIn("Launch agent label: io.harnessmonitor.daemon.bart-dev", completed.stdout)
            self.assertIn("mise run monitor:user:build", completed.stdout)
            self.assertIn("mise run monitor:user:daemon:dev", completed.stdout)
            self.assertEqual(
                (app_root / ".xcode-user-derived-data-path").read_text().strip(),
                str(repo_root / "xcode-derived" / "profiles" / "bart-dev"),
            )
            for settings_path in (
                app_root
                / "HarnessMonitor.xcworkspace"
                / "xcuserdata"
                / "bartsmykla.xcuserdatad"
                / "WorkspaceSettings.xcsettings",
                app_root
                / "HarnessMonitor.xcodeproj"
                / "project.xcworkspace"
                / "xcuserdata"
                / "bartsmykla.xcuserdatad"
                / "WorkspaceSettings.xcsettings",
            ):
                with self.subTest(settings_path=settings_path):
                    self.assertIn(
                        str(repo_root / "xcode-derived" / "profiles" / "bart-dev"),
                        settings_path.read_text(),
                    )

    def test_user_runtime_profile_script_rejects_agent_sessions(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            home_dir = Path(tmp_dir) / "home"
            home_dir.mkdir()
            repo_root = Path(tmp_dir) / "repo"
            app_root = repo_root / "apps" / "harness-monitor-macos"
            scripts_root = app_root / "Scripts"
            lib_root = scripts_root / "lib"
            lib_root.mkdir(parents=True)
            shutil.copy(USER_PROFILE_SCRIPT, scripts_root / "user-runtime-profile.sh")
            shutil.copy(HELPER_PATH, lib_root / "runtime-profile.sh")
            common_repo_root_destination = repo_root / "scripts" / "lib"
            common_repo_root_destination.mkdir(parents=True)
            shutil.copy(
                COMMON_REPO_ROOT_SOURCE,
                common_repo_root_destination / "common-repo-root.sh",
            )
            env = base_env()
            env.update(
                {
                    "HOME": str(home_dir),
                    "CODEX_SESSION_ID": "sess-agent-123",
                }
            )

            completed = subprocess.run(
                ["bash", str(scripts_root / "user-runtime-profile.sh")],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn(
                "Agent sessions must not use the Harness Monitor user profile lane",
                completed.stderr,
            )

    def test_user_runtime_profile_script_allows_agent_sessions_with_override(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            home_dir = Path(tmp_dir) / "home"
            home_dir.mkdir()
            repo_root = Path(tmp_dir) / "repo"
            app_root = repo_root / "apps" / "harness-monitor-macos"
            scripts_root = app_root / "Scripts"
            lib_root = scripts_root / "lib"
            lib_root.mkdir(parents=True)
            shutil.copy(USER_PROFILE_SCRIPT, scripts_root / "user-runtime-profile.sh")
            shutil.copy(HELPER_PATH, lib_root / "runtime-profile.sh")
            common_repo_root_destination = repo_root / "scripts" / "lib"
            common_repo_root_destination.mkdir(parents=True)
            shutil.copy(
                COMMON_REPO_ROOT_SOURCE,
                common_repo_root_destination / "common-repo-root.sh",
            )
            env = base_env()
            env.update(
                {
                    "HOME": str(home_dir),
                    "CODEX_SESSION_ID": "sess-agent-123",
                    "HARNESS_MONITOR_ALLOW_AGENT_USER_PROFILE": "1",
                    "HARNESS_MONITOR_USER_RUNTIME_PROFILE": "Bart Dev",
                }
            )

            completed = subprocess.run(
                ["bash", str(scripts_root / "user-runtime-profile.sh")],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("Harness Monitor user profile: bart-dev", completed.stdout)


if __name__ == "__main__":
    unittest.main()
