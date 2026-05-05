from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_runtime_profile import (
    COMMON_REPO_ROOT_SOURCE,
    CURRENT_AGENT_SESSION_ID,
    HELPER_PATH,
    NON_AGENT_PROFILE_RAW,
    USER_PROFILE_SCRIPT,
    base_env,
)


def prepare_user_profile_script_fixture(
    tmp_dir: str,
) -> tuple[Path, Path, Path]:
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
    return home_dir, repo_root, app_root


class UserRuntimeProfileScriptTests(unittest.TestCase):
    def test_user_runtime_profile_script_prints_profile_details(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            home_dir, repo_root, app_root = prepare_user_profile_script_fixture(tmp_dir)
            workspace_roots = (
                app_root / "HarnessMonitor.xcworkspace",
                app_root / "HarnessMonitor.xcodeproj" / "project.xcworkspace",
            )
            for workspace_root in workspace_roots:
                workspace_root.mkdir(parents=True)
            env = base_env()
            env.update(
                {
                    "HOME": str(home_dir),
                    "HARNESS_MONITOR_USER_RUNTIME_PROFILE": "Bart Dev",
                    "USER": "monitor",
                }
            )

            completed = subprocess.run(
                ["bash", str(app_root / "Scripts" / "user-runtime-profile.sh")],
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
            self.assertIn(
                "Launch agent label: io.harnessmonitor.daemon.bart-dev",
                completed.stdout,
            )
            self.assertIn("mise run monitor:user:build", completed.stdout)
            self.assertIn("mise run monitor:user:daemon:dev", completed.stdout)
            self.assertEqual(
                (app_root / ".xcode-user-derived-data-path").read_text().strip(),
                str(repo_root / "xcode-derived" / "profiles" / "bart-dev"),
            )
            self.assert_workspace_settings_point_to_profile(app_root, repo_root)

    def test_user_runtime_profile_script_rejects_agent_sessions(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            home_dir, _, app_root = prepare_user_profile_script_fixture(tmp_dir)
            env = base_env()
            env.update(
                {
                    "HOME": str(home_dir),
                    "CODEX_SESSION_ID": CURRENT_AGENT_SESSION_ID,
                }
            )

            completed = subprocess.run(
                ["bash", str(app_root / "Scripts" / "user-runtime-profile.sh")],
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
            home_dir, _, app_root = prepare_user_profile_script_fixture(tmp_dir)
            env = base_env()
            env.update(
                {
                    "HOME": str(home_dir),
                    "CODEX_SESSION_ID": CURRENT_AGENT_SESSION_ID,
                    "HARNESS_MONITOR_ALLOW_AGENT_USER_PROFILE": "1",
                    "HARNESS_MONITOR_USER_RUNTIME_PROFILE": NON_AGENT_PROFILE_RAW,
                }
            )

            completed = subprocess.run(
                ["bash", str(app_root / "Scripts" / "user-runtime-profile.sh")],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("Harness Monitor user profile: bart-dev", completed.stdout)

    def assert_workspace_settings_point_to_profile(
        self,
        app_root: Path,
        repo_root: Path,
    ) -> None:
        for settings_path in (
            app_root
            / "HarnessMonitor.xcworkspace"
            / "xcuserdata"
            / "monitor.xcuserdatad"
            / "WorkspaceSettings.xcsettings",
            app_root
            / "HarnessMonitor.xcodeproj"
            / "project.xcworkspace"
            / "xcuserdata"
            / "monitor.xcuserdatad"
            / "WorkspaceSettings.xcsettings",
        ):
            with self.subTest(settings_path=settings_path):
                self.assertIn(
                    str(repo_root / "xcode-derived" / "profiles" / "bart-dev"),
                    settings_path.read_text(),
                )


if __name__ == "__main__":
    unittest.main()
