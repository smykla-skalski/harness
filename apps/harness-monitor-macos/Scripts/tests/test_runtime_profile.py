from __future__ import annotations

import hashlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
HELPER_PATH = APP_ROOT / "Scripts" / "lib" / "runtime-profile.sh"
USER_PROFILE_SCRIPT = APP_ROOT / "Scripts" / "user-runtime-profile.sh"
DEFAULT_APP_GROUP_ID = "Q498EB36N4.io.harnessmonitor"


def run_helper(script: str, env: dict[str, str]) -> str:
    completed = subprocess.run(
        ["bash", "-lc", f"source {HELPER_PATH}; {script}"],
        check=True,
        capture_output=True,
        text=True,
        env=env,
    )
    return completed.stdout.strip()


def expected_profile_port(profile: str) -> str:
    digest_prefix = hashlib.sha256(profile.encode("utf-8")).hexdigest()[:8]
    return str(4600 + (int(digest_prefix, 16) % 20000))


class RuntimeProfileHelperTests(unittest.TestCase):
    def test_profile_env_resolves_profiled_paths_port_and_label(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            home_dir = Path(tmp_dir) / "home"
            home_dir.mkdir()
            env = os.environ.copy()
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
            env = os.environ.copy()
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
            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(Path(tmp_dir) / "home"),
                    "USER": "bart.smykla@konghq.com",
                }
            )

            output = run_helper("harness_monitor_default_user_runtime_profile", env)

            self.assertEqual(output, "bartsmykla")

    def test_user_runtime_profile_script_prints_profile_details(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            home_dir = Path(tmp_dir) / "home"
            home_dir.mkdir()
            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home_dir),
                    "HARNESS_MONITOR_USER_RUNTIME_PROFILE": "Bart Dev",
                }
            )

            completed = subprocess.run(
                ["bash", str(USER_PROFILE_SCRIPT)],
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


if __name__ == "__main__":
    unittest.main()
