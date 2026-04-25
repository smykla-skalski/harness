from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[4]
APP_ROOT = REPO_ROOT / "apps" / "harness-monitor-macos"
SCRIPT_PATH = APP_ROOT / "Scripts" / "test-agents-e2e.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class TestAgentsE2EScriptTests(unittest.TestCase):
    def make_temp_repo(self) -> tuple[Path, Path, Path, Path]:
        repo_root = Path(self.tmp_dir.name) / "repo"
        app_root = repo_root / "apps" / "harness-monitor-macos"
        scripts_root = app_root / "Scripts"
        scripts_lib_root = scripts_root / "lib"
        repo_scripts_root = repo_root / "scripts"
        repo_scripts_lib_root = repo_scripts_root / "lib"
        scripts_lib_root.mkdir(parents=True)
        repo_scripts_lib_root.mkdir(parents=True)

        shutil.copy2(SCRIPT_PATH, scripts_root / "test-agents-e2e.sh")
        shutil.copy2(
            APP_ROOT / "Scripts" / "lib" / "xcodebuild-destination.sh",
            scripts_lib_root / "xcodebuild-destination.sh",
        )
        shutil.copy2(
            APP_ROOT / "Scripts" / "lib" / "rtk-shell.sh",
            scripts_lib_root / "rtk-shell.sh",
        )
        shutil.copy2(
            REPO_ROOT / "scripts" / "lib" / "common-repo-root.sh",
            repo_scripts_lib_root / "common-repo-root.sh",
        )

        write_executable(
            scripts_root / "generate.sh",
            "#!/bin/bash\nset -euo pipefail\n",
        )
        write_executable(
            repo_scripts_root / "cargo-local.sh",
            """#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == "--print-env" ]]; then
  printf 'CARGO_TARGET_DIR=%s/target\\n' "$(pwd)"
  exit 0
fi
exit 0
""",
        )

        fake_bin = repo_root / "bin"
        fake_bin.mkdir()
        write_executable(
            fake_bin / "codex",
            "#!/bin/bash\nset -euo pipefail\nexit 0\n",
        )

        return repo_root, app_root, scripts_root, fake_bin

    def run_script(
        self,
        *,
        configure_fake_runner,
        configure_fake_harness=None,
    ) -> subprocess.CompletedProcess[str]:
        repo_root, _, scripts_root, fake_bin = self.make_temp_repo()
        configure_fake_runner(repo_root, scripts_root)
        if configure_fake_harness is not None:
            configure_fake_harness(repo_root)

        return subprocess.run(
            ["bash", str(scripts_root / "test-agents-e2e.sh")],
            check=False,
            capture_output=True,
            text=True,
            env={
                **os.environ,
                "HOME": str(repo_root),
                "PATH": f"{fake_bin}:/usr/bin:/bin",
                "TMPDIR": str(repo_root / "tmp"),
            },
            cwd=repo_root,
        )

    def setUp(self) -> None:
        self.tmp_dir = tempfile.TemporaryDirectory()

    def tearDown(self) -> None:
        self.tmp_dir.cleanup()

    def test_build_for_testing_skips_daemon_bundle_version_check(self) -> None:
        runner_env_log = Path(self.tmp_dir.name) / "repo" / "runner-env.log"

        completed = self.run_script(
            configure_fake_runner=lambda repo_root, scripts_root: write_executable(
                scripts_root / "xcodebuild-with-lock.sh",
                f"""#!/bin/bash
set -euo pipefail
printf 'HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE=%s\\n' "${{HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE:-}}" > "{runner_env_log}"
exit 23
""",
            )
        )

        self.assertEqual(completed.returncode, 23, completed.stderr)
        self.assertEqual(
            runner_env_log.read_text().strip(),
            "HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE=1",
        )

    def test_session_commands_share_isolated_data_root_with_daemon(self) -> None:
        harness_env_log = Path(self.tmp_dir.name) / "repo" / "harness-env.log"

        def configure_fake_runner(repo_root: Path, scripts_root: Path) -> None:
            xctestrun_path = (
                repo_root
                / "xcode-derived"
                / "Build"
                / "Products"
                / "HarnessMonitorAgentsE2E_fake.xctestrun"
            )
            write_executable(
                scripts_root / "xcodebuild-with-lock.sh",
                f"""#!/bin/bash
set -euo pipefail
mkdir -p "$(dirname "{xctestrun_path}")"
if printf '%s\\n' "$@" | /usr/bin/grep -q 'build-for-testing'; then
  /usr/bin/python3 - <<'PY'
import plistlib
from pathlib import Path

path = Path(r"{xctestrun_path}")
payload = {{
    "HarnessMonitorAgentsE2ETests": {{
        "EnvironmentVariables": {{}},
        "TestingEnvironmentVariables": {{}},
    }}
}}
with path.open("wb") as handle:
    plistlib.dump(payload, handle, sort_keys=False)
PY
fi
exit 0
""",
            )

        def configure_fake_harness(repo_root: Path) -> None:
            target_dir = repo_root / "target" / "debug"
            target_dir.mkdir(parents=True)
            write_executable(
                target_dir / "harness",
                f"""#!/bin/bash
set -euo pipefail
case "${{1:-}}" in
  daemon)
    case "${{2:-}}" in
      serve)
        while true; do sleep 1; done
        ;;
      status)
        exit 0
        ;;
    esac
    ;;
  bridge)
    case "${{2:-}}" in
      start)
        while true; do sleep 1; done
        ;;
      status)
        printf '{{"running":true,"capabilities":{{"codex":{{"healthy":true}},"agent-tui":{{"healthy":true}}}}}}\\n'
        exit 0
        ;;
    esac
    ;;
  session)
    if [[ "${{2:-}}" == "start" ]]; then
      printf 'HARNESS_DAEMON_DATA_HOME=%s\\n' "${{HARNESS_DAEMON_DATA_HOME:-}}" > "{harness_env_log}"
      printf 'XDG_DATA_HOME=%s\\n' "${{XDG_DATA_HOME:-}}" >> "{harness_env_log}"
      exit 17
    fi
    ;;
esac
exit 0
""",
            )

        completed = self.run_script(
            configure_fake_runner=configure_fake_runner,
            configure_fake_harness=configure_fake_harness,
        )

        self.assertEqual(completed.returncode, 17, completed.stderr)
        env_lines = harness_env_log.read_text().splitlines()
        daemon_home = next(
            line.split("=", 1)[1]
            for line in env_lines
            if line.startswith("HARNESS_DAEMON_DATA_HOME=")
        )
        xdg_home = next(
            line.split("=", 1)[1] for line in env_lines if line.startswith("XDG_DATA_HOME=")
        )
        self.assertEqual(xdg_home, daemon_home)


if __name__ == "__main__":
    unittest.main()
