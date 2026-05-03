from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
AGENT_SCRIPT_SOURCE = APP_ROOT / "Scripts" / "agent-xcode-env.sh"
RUNTIME_PROFILE_SOURCE = APP_ROOT / "Scripts" / "lib" / "runtime-profile.sh"
COMMON_REPO_ROOT_SOURCE = APP_ROOT.parents[1] / "scripts" / "lib" / "common-repo-root.sh"
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


def prepare_agent_script_root(temp_root: Path) -> tuple[Path, Path]:
    repo_root = temp_root / "repo"
    app_root = repo_root / "apps" / "harness-monitor-macos"
    scripts_root = app_root / "Scripts"
    lib_root = scripts_root / "lib"
    lib_root.mkdir(parents=True)
    shutil.copy(AGENT_SCRIPT_SOURCE, scripts_root / "agent-xcode-env.sh")
    (scripts_root / "agent-xcode-env.sh").chmod(
        (scripts_root / "agent-xcode-env.sh").stat().st_mode | stat.S_IXUSR
    )
    shutil.copy(RUNTIME_PROFILE_SOURCE, lib_root / "runtime-profile.sh")
    common_repo_root_destination = repo_root / "scripts" / "lib"
    common_repo_root_destination.mkdir(parents=True)
    shutil.copy(
        COMMON_REPO_ROOT_SOURCE,
        common_repo_root_destination / "common-repo-root.sh",
    )
    return repo_root, scripts_root / "agent-xcode-env.sh"


def base_env() -> dict[str, str]:
    env = os.environ.copy()
    for key in AGENT_SESSION_ENV_KEYS:
        env.pop(key, None)
    env.pop("HARNESS_MONITOR_ALLOW_NON_AGENT_RUNTIME_PROFILE", None)
    env.pop("HARNESS_MONITOR_ALLOW_AGENT_USER_PROFILE", None)
    return env


class AgentXcodeEnvTests(unittest.TestCase):
    def test_prints_isolated_agent_profile_details(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            repo_root, script_path = prepare_agent_script_root(temp_root)
            home_dir = temp_root / "home"
            home_dir.mkdir()

            env = base_env()
            env.update(
                {
                    "HOME": str(home_dir),
                    "CODEX_SESSION_ID": "sess-agent-123",
                }
            )

            completed = subprocess.run(
                ["bash", str(script_path)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn(
                "Harness Monitor agent profile: agent-sess-agent-123",
                completed.stdout,
            )
            self.assertIn(
                f"DerivedData: {repo_root}/xcode-derived/profiles/agent-sess-agent-123",
                completed.stdout,
            )
            self.assertIn(
                f"XcodeBuildMCP socket: {home_dir}/.xcodebuildmcp/agents/agent-sess-agent-123.sock",
                completed.stdout,
            )
            self.assertIn(
                "Xcode IDE tools: disabled for agent isolation",
                completed.stdout,
            )
            self.assertIn("mise run monitor:agent:xcodebuildmcp", completed.stdout)

    def test_rejects_non_agent_runtime_profile_override(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            _, script_path = prepare_agent_script_root(temp_root)
            home_dir = temp_root / "home"
            home_dir.mkdir()

            env = base_env()
            env.update(
                {
                    "HOME": str(home_dir),
                    "CODEX_SESSION_ID": "sess-agent-123",
                    "HARNESS_MONITOR_RUNTIME_PROFILE": "claude-main",
                }
            )

            completed = subprocess.run(
                ["bash", str(script_path)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn(
                "Agent sessions must use an isolated agent-* runtime profile",
                completed.stderr,
            )

    def test_blocks_xcode_ide_without_explicit_agent_override(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            _, script_path = prepare_agent_script_root(temp_root)
            home_dir = temp_root / "home"
            home_dir.mkdir()

            env = base_env()
            env.update(
                {
                    "HOME": str(home_dir),
                    "CODEX_SESSION_ID": "sess-agent-123",
                }
            )

            completed = subprocess.run(
                ["bash", str(script_path), "xcodebuildmcp", "xcode-ide", "list-tools"],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn(
                "agent Xcode IDE tools are disabled by default",
                completed.stderr,
            )

    def test_exports_agent_developer_dir_override(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            repo_root, script_path = prepare_agent_script_root(temp_root)
            home_dir = temp_root / "home"
            home_dir.mkdir()
            developer_dir = temp_root / "Xcode-Agent.app" / "Contents" / "Developer"
            developer_dir.mkdir(parents=True)

            env = base_env()
            env.update(
                {
                    "HOME": str(home_dir),
                    "CODEX_SESSION_ID": "sess-agent-123",
                    "HARNESS_MONITOR_AGENT_DEVELOPER_DIR": str(developer_dir),
                }
            )

            completed = subprocess.run(
                [
                    "bash",
                    str(script_path),
                    "bash",
                    "-lc",
                    "printf '%s\\n%s\\n%s\\n' "
                    '"$DEVELOPER_DIR" '
                    '"$XCODEBUILDMCP_DERIVED_DATA_PATH" '
                    '"$XCODEBUILDMCP_SOCKET"',
                ],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            developer_output, derived_data_output, socket_output = (
                completed.stdout.strip().splitlines()
            )
            self.assertEqual(developer_output, str(developer_dir))
            self.assertEqual(
                derived_data_output,
                str(repo_root / "xcode-derived" / "profiles" / "agent-sess-agent-123"),
            )
            self.assertEqual(
                socket_output,
                str(
                    home_dir
                    / ".xcodebuildmcp"
                    / "agents"
                    / "agent-sess-agent-123.sock"
                ),
            )


if __name__ == "__main__":
    unittest.main()
