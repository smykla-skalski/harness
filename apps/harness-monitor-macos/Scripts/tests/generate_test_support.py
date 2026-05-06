from __future__ import annotations

import os
import plistlib
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
GENERATE_SOURCE = APP_ROOT / "Scripts" / "generate.sh"
POST_GENERATE_SOURCE = APP_ROOT / "Scripts" / "post-generate.sh"
PREPARE_APP_ENTITLEMENTS_SOURCE = APP_ROOT / "Scripts" / "prepare-app-entitlements.sh"
SWIFT_TOOL_ENV_SOURCE = APP_ROOT / "Scripts" / "lib" / "swift-tool-env.sh"
NON_INDEXABLE_ROOTS_SOURCE = APP_ROOT / "Scripts" / "lib" / "non-indexable-roots.sh"
XCODE_VERSION_SOURCE = APP_ROOT / "Scripts" / "lib" / "xcode-version.sh"
MONITOR_LANES_SOURCE = APP_ROOT / "Scripts" / "lib" / "monitor-lanes.sh"
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


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def base_env() -> dict[str, str]:
    env = os.environ.copy()
    for key in AGENT_SESSION_ENV_KEYS:
        env.pop(key, None)
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
    ):
        env.pop(key, None)
    return env

