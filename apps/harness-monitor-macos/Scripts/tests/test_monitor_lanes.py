from __future__ import annotations

import hashlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
LANES_HELPER = APP_ROOT / "Scripts" / "lib" / "monitor-lanes.sh"
RUNTIME_ENV_SCRIPT = APP_ROOT / "Scripts" / "monitor-runtime-env.sh"


def base_env() -> dict[str, str]:
    env = os.environ.copy()
    for key in (
        "HARNESS_MONITOR_RUNTIME_PROFILE",
        "HARNESS_MONITOR_USER_RUNTIME_PROFILE",
        "HARNESS_MONITOR_ALLOW_NON_AGENT_RUNTIME_PROFILE",
        "HARNESS_MONITOR_ALLOW_AGENT_USER_PROFILE",
        "HARNESS_MONITOR_AGENT_DEVELOPER_DIR",
        "HARNESS_MONITOR_BUILD_LANE",
        "HARNESS_MONITOR_RUNTIME_LANE",
        "HARNESS_DAEMON_DATA_HOME",
        "HARNESS_CODEX_WS_PORT",
        "HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL",
        "XCODEBUILD_DERIVED_DATA_PATH",
        "XCODEBUILDMCP_SOCKET",
    ):
        env.pop(key, None)
    return env


def run_helper(script: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-lc", f"source {LANES_HELPER}; {script}"],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )


def expected_default_runtime_lane(checkout_root: Path) -> str:
    checkout = checkout_root.resolve()
    digest = hashlib.sha256(str(checkout).encode()).hexdigest()[:8]
    return f"{checkout.name}-{digest}"


def expected_port(lane: str) -> str:
    digest = hashlib.sha256(lane.encode()).hexdigest()[:8]
    return str(4600 + (int(digest, 16) % 20000))


class MonitorLaneHelperTests(unittest.TestCase):
    def test_default_build_lane_uses_shared_derived_data(self) -> None:
        env = base_env()

        completed = run_helper(
            'harness_monitor_build_derived_data_path "/repo-common"',
            env,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.strip(), "/repo-common/xcode-derived")

    def test_named_build_lane_uses_xcode_derived_lanes_root(self) -> None:
        env = base_env()
        env["HARNESS_MONITOR_BUILD_LANE"] = "Agent Session 123"

        completed = run_helper(
            'harness_monitor_build_derived_data_path "/repo-common"',
            env,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(
            completed.stdout.strip(),
            "/repo-common/xcode-derived-lanes/agent-session-123",
        )

    def test_runtime_lane_defaults_to_worktree_stable_slug(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            checkout_root = Path(tmp_dir) / "harness-worktree"
            checkout_root.mkdir()
            env = base_env()
            env["HOME"] = str(Path(tmp_dir) / "home")

            completed = run_helper(
                f'printf "%s\\n%s\\n%s\\n%s\\n" '
                f'"$(harness_monitor_runtime_lane "{checkout_root}")" '
                f'"$(harness_monitor_runtime_daemon_data_home "{checkout_root}")" '
                f'"$(harness_monitor_runtime_codex_ws_port "{checkout_root}")" '
                f'"$(harness_monitor_runtime_launch_agent_label "{checkout_root}")"',
                env,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            lane, daemon_home, port, label = completed.stdout.strip().splitlines()
            expected_lane = expected_default_runtime_lane(checkout_root)
            self.assertEqual(lane, expected_lane)
            self.assertEqual(
                daemon_home,
                str(
                    Path(env["HOME"])
                    / "Library"
                    / "Group Containers"
                    / "Q498EB36N4.io.harnessmonitor"
                    / "runtime-lanes"
                    / expected_lane
                ),
            )
            self.assertEqual(port, expected_port(expected_lane))
            self.assertEqual(label, f"io.harnessmonitor.daemon.{expected_lane}")

    def test_legacy_profile_env_is_rejected(self) -> None:
        env = base_env()
        env["HARNESS_MONITOR_RUNTIME_PROFILE"] = "old-profile"

        completed = run_helper(
            'harness_monitor_build_derived_data_path "/repo-common"',
            env,
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("HARNESS_MONITOR_RUNTIME_PROFILE is no longer supported", completed.stderr)

    def test_runtime_env_script_exports_lane_for_child_command(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            env = base_env()
            env["HOME"] = str(Path(tmp_dir) / "home")
            env["HARNESS_MONITOR_RUNTIME_LANE"] = "Agent 42"

            completed = subprocess.run(
                [
                    "bash",
                    str(RUNTIME_ENV_SCRIPT),
                    "bash",
                    "-lc",
                    "printf '%s\\n%s\\n%s\\n%s\\n' "
                    '"$HARNESS_MONITOR_RUNTIME_LANE" '
                    '"$HARNESS_DAEMON_DATA_HOME" '
                    '"$HARNESS_CODEX_WS_PORT" '
                    '"$XCODEBUILDMCP_SOCKET"',
                ],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            lane, daemon_home, port, socket = completed.stdout.strip().splitlines()
            self.assertEqual(lane, "agent-42")
            self.assertEqual(
                daemon_home,
                str(
                    Path(env["HOME"])
                    / "Library"
                    / "Group Containers"
                    / "Q498EB36N4.io.harnessmonitor"
                    / "runtime-lanes"
                    / "agent-42"
                ),
            )
            self.assertEqual(port, expected_port("agent-42"))
            self.assertEqual(
                socket,
                str(Path(env["HOME"]) / ".xcodebuildmcp" / "harness-monitor-agent-42.sock"),
            )


if __name__ == "__main__":
    unittest.main()
