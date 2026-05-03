from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_SOURCE = APP_ROOT / "Scripts" / "xcode-native-bridge.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class XcodeNativeBridgeScriptTests(unittest.TestCase):
    def test_ensure_installs_bridge_and_opens_xcode_when_needed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            repo_root = temp_root / "repo"
            app_root = repo_root / "apps" / "harness-monitor-macos"
            scripts_root = app_root / "Scripts"
            fake_bin = temp_root / "bin"
            fake_bin.mkdir(parents=True)
            scripts_root.mkdir(parents=True)

            script_path = scripts_root / "xcode-native-bridge.sh"
            shutil.copy(SCRIPT_SOURCE, script_path)
            script_path.chmod(script_path.stat().st_mode | stat.S_IXUSR)

            workspace_path = app_root / "HarnessMonitor.xcworkspace"
            workspace_path.mkdir()
            home_dir = temp_root / "home"
            home_dir.mkdir()
            launch_agent_plist = home_dir / "Library" / "LaunchAgents" / "com.xcode-cli.bridge.plist"
            ctl_log = temp_root / "xcode-cli-ctl.log"
            cli_log = temp_root / "xcode-cli.log"
            open_log = temp_root / "open.log"
            state_dir = temp_root / "state"
            state_dir.mkdir()

            write_executable(
                fake_bin / "pgrep",
                f"""#!/bin/bash
set -euo pipefail
if [[ -f "{state_dir}/xcode-running" ]]; then
  printf '1234\\n'
  exit 0
fi
exit 1
""",
            )
            write_executable(
                fake_bin / "open",
                f"""#!/bin/bash
set -euo pipefail
printf '%s\\n' "$*" >> "{open_log}"
touch "{state_dir}/xcode-running"
""",
            )
            write_executable(
                fake_bin / "xcode-cli-ctl",
                f"""#!/bin/bash
set -euo pipefail
printf '%s\\n' "$*" >> "{ctl_log}"
case "${{1:-}}" in
  status)
    if [[ -f "{state_dir}/healthy" ]]; then
      cat <<EOF
Service: running (pid 111)
Healthy: yes
Endpoint: http://127.0.0.1:48321/mcp
Plist: {launch_agent_plist}
Logs: {home_dir}/Library/Logs/xcode-cli.stderr.log
EOF
    else
      cat <<EOF
Service: stopped
Healthy: no
Endpoint: http://127.0.0.1:48321/mcp
Plist: {launch_agent_plist}
Logs: {home_dir}/Library/Logs/xcode-cli.stderr.log
EOF
    fi
    ;;
  install)
    mkdir -p "$(dirname "{launch_agent_plist}")"
    touch "{launch_agent_plist}"
    touch "{state_dir}/healthy"
    ;;
  restart)
    mkdir -p "$(dirname "{launch_agent_plist}")"
    touch "{launch_agent_plist}"
    touch "{state_dir}/healthy"
    ;;
  logs)
    echo "fake xcode-native logs"
    ;;
  *)
    echo "unexpected xcode-cli-ctl args: $*" >&2
    exit 1
    ;;
esac
""",
            )
            write_executable(
                fake_bin / "xcode-cli",
                f"""#!/bin/bash
set -euo pipefail
printf '%s\\n' "$*" >> "{cli_log}"
if [[ "${{1:-}}" != "windows" ]]; then
  echo "unexpected xcode-cli args: $*" >&2
  exit 1
fi
if [[ ! -f "{state_dir}/healthy" ]]; then
  echo "bridge not healthy" >&2
  exit 1
fi
printf '{{"message":"ok"}}\\n'
""",
            )

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home_dir),
                    "PATH": f"{fake_bin}:/usr/bin:/bin",
                    "BASH_ENV": "/dev/null",
                    "XCODE_NATIVE_WORKSPACE_PATH": str(workspace_path),
                    "XCODE_NATIVE_BRIDGE_PLIST": str(launch_agent_plist),
                    "XCODE_NATIVE_HEALTH_TIMEOUT_SECONDS": "3",
                    "XCODE_NATIVE_XCODE_WAIT_SECONDS": "3",
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
            self.assertIn("Service: running", completed.stdout)
            self.assertIn("Healthy: yes", completed.stdout)
            self.assertTrue(launch_agent_plist.exists())
            self.assertIn("-a Xcode", open_log.read_text())
            self.assertIn("install --port 48321", ctl_log.read_text())
            self.assertIn("windows --json", cli_log.read_text())

    def test_ensure_generates_workspace_before_restarting_existing_bridge(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            repo_root = temp_root / "repo"
            app_root = repo_root / "apps" / "harness-monitor-macos"
            scripts_root = app_root / "Scripts"
            fake_bin = temp_root / "bin"
            fake_bin.mkdir(parents=True)
            scripts_root.mkdir(parents=True)

            script_path = scripts_root / "xcode-native-bridge.sh"
            shutil.copy(SCRIPT_SOURCE, script_path)
            script_path.chmod(script_path.stat().st_mode | stat.S_IXUSR)

            workspace_path = app_root / "HarnessMonitor.xcworkspace"
            home_dir = temp_root / "home"
            home_dir.mkdir()
            launch_agent_plist = home_dir / "Library" / "LaunchAgents" / "com.xcode-cli.bridge.plist"
            launch_agent_plist.parent.mkdir(parents=True)
            launch_agent_plist.write_text("existing\n")
            ctl_log = temp_root / "xcode-cli-ctl.log"
            cli_log = temp_root / "xcode-cli.log"
            profile_log = temp_root / "user-profile.log"
            generate_log = temp_root / "generate.log"
            state_dir = temp_root / "state"
            state_dir.mkdir()
            (state_dir / "xcode-running").write_text("1\n")

            profile_script = temp_root / "user-runtime-profile.sh"
            generate_script = temp_root / "generate.sh"
            write_executable(
                profile_script,
                f"""#!/bin/bash
set -euo pipefail
printf '%s\\n' "$*" >> "{profile_log}"
exec "$@"
""",
            )
            write_executable(
                generate_script,
                f"""#!/bin/bash
set -euo pipefail
printf 'generated\\n' >> "{generate_log}"
mkdir -p "{workspace_path}"
""",
            )
            write_executable(
                fake_bin / "pgrep",
                f"""#!/bin/bash
set -euo pipefail
if [[ -f "{state_dir}/xcode-running" ]]; then
  printf '2345\\n'
  exit 0
fi
exit 1
""",
            )
            write_executable(
                fake_bin / "open",
                """#!/bin/bash
set -euo pipefail
echo "open should not be called" >&2
exit 1
""",
            )
            write_executable(
                fake_bin / "xcode-cli-ctl",
                f"""#!/bin/bash
set -euo pipefail
printf '%s\\n' "$*" >> "{ctl_log}"
case "${{1:-}}" in
  status)
    if [[ -f "{state_dir}/healthy" ]]; then
      cat <<EOF
Service: running (pid 222)
Healthy: yes
Endpoint: http://127.0.0.1:48321/mcp
Plist: {launch_agent_plist}
Logs: {home_dir}/Library/Logs/xcode-cli.stderr.log
EOF
    else
      cat <<EOF
Service: stopped
Healthy: no
Endpoint: http://127.0.0.1:48321/mcp
Plist: {launch_agent_plist}
Logs: {home_dir}/Library/Logs/xcode-cli.stderr.log
EOF
    fi
    ;;
  install)
    echo "install should not be called" >&2
    exit 1
    ;;
  restart)
    touch "{state_dir}/healthy"
    ;;
  logs)
    echo "fake logs"
    ;;
  *)
    echo "unexpected xcode-cli-ctl args: $*" >&2
    exit 1
    ;;
esac
""",
            )
            write_executable(
                fake_bin / "xcode-cli",
                f"""#!/bin/bash
set -euo pipefail
printf '%s\\n' "$*" >> "{cli_log}"
if [[ "${{1:-}}" != "windows" ]]; then
  echo "unexpected xcode-cli args: $*" >&2
  exit 1
fi
if [[ ! -f "{state_dir}/healthy" ]]; then
  echo "bridge not healthy" >&2
  exit 1
fi
printf '{{"message":"ok"}}\\n'
""",
            )

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home_dir),
                    "PATH": f"{fake_bin}:/usr/bin:/bin",
                    "BASH_ENV": "/dev/null",
                    "MONITOR_USER_PROFILE_SCRIPT": str(profile_script),
                    "MONITOR_GENERATE_SCRIPT": str(generate_script),
                    "XCODE_NATIVE_WORKSPACE_PATH": str(workspace_path),
                    "XCODE_NATIVE_BRIDGE_PLIST": str(launch_agent_plist),
                    "XCODE_NATIVE_HEALTH_TIMEOUT_SECONDS": "3",
                    "XCODE_NATIVE_XCODE_WAIT_SECONDS": "3",
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
            self.assertTrue(workspace_path.exists())
            self.assertIn(str(generate_script), profile_log.read_text())
            self.assertIn("generated", generate_log.read_text())
            self.assertIn("restart", ctl_log.read_text())
            self.assertNotIn("install", ctl_log.read_text())
            self.assertIn("windows --json", cli_log.read_text())


if __name__ == "__main__":
    unittest.main()
