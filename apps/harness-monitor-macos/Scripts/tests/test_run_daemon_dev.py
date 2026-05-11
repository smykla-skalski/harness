from __future__ import annotations

import os
import signal
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = APP_ROOT / "Scripts" / "run-daemon-dev.sh"
SUPERVISOR_PATH = APP_ROOT / "Scripts" / "run-daemon-dev.py"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class RunDaemonDevScriptTests(unittest.TestCase):
    def wait_for_path(self, path: Path, timeout_seconds: float = 5.0) -> None:
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            if path.exists():
                return
            time.sleep(0.05)
        self.fail(f"timed out waiting for {path}")

    def lane_manifest_path(self, home_dir: Path, lane: str) -> Path:
        return (
            home_dir
            / "Library"
            / "Group Containers"
            / "Q498EB36N4.io.harnessmonitor"
            / "runtime-lanes"
            / lane
            / "harness"
            / "daemon"
            / "manifest.json"
        )

    def write_fake_harness(self, path: Path, mode: str) -> None:
        content = """#!/usr/bin/env bash
set -euo pipefail

mode="__MODE__"

if [[ "${1:-}" != "daemon" || "${2:-}" != "dev" ]]; then
  printf 'unexpected args: %s\\n' "$*" >&2
  exit 64
fi

manifest="$HARNESS_DAEMON_DATA_HOME/harness/daemon/manifest.json"
mkdir -p "$(dirname "$manifest")"

case "$mode" in
  success)
    printf 'fake daemon exited cleanly\\n'
    exit 0
    ;;
  fail)
    printf 'fake daemon failed\\n' >&2
    exit 23
    ;;
  interrupt-cleans)
    printf '{"pid":999}\\n' >"$manifest"
    trap 'rm -f "$manifest"; printf "fake daemon cleaned manifest on interrupt\\n"; exit 130' INT TERM HUP
    while :; do
      sleep 1
    done
    ;;
  interrupt-leaks)
    printf '{"pid":999}\\n' >"$manifest"
    trap 'printf "fake daemon leaked manifest on interrupt\\n"; exit 130' INT TERM HUP
    while :; do
      sleep 1
    done
    ;;
  *)
    printf 'unknown fake mode: %s\\n' "$mode" >&2
    exit 64
    ;;
esac
"""
        write_executable(path, content.replace("__MODE__", mode))

    def run_script(
        self,
        temp_root: Path,
        *,
        mode: str,
        lane: str,
        send_signal: int | None = None,
        extra_env: dict[str, str] | None = None,
    ) -> tuple[subprocess.Popen[str], str, str, Path, Path]:
        fake_harness = temp_root / f"fake-harness-{mode}.sh"
        self.write_fake_harness(fake_harness, mode)

        home_dir = temp_root / f"home-{lane}"
        home_dir.mkdir(parents=True, exist_ok=True)
        log_dir = temp_root / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        manifest_path = self.lane_manifest_path(home_dir, lane)

        env = os.environ.copy()
        env.update(
            {
                "HOME": str(home_dir),
                "HARNESS_MONITOR_RUNTIME_LANE": lane,
                "HARNESS_MONITOR_DAEMON_DEV_BIN": str(fake_harness),
                "HARNESS_MONITOR_DAEMON_DEV_LOG_DIR": str(log_dir),
                "TMPDIR": str(temp_root),
                "BASH_ENV": "/dev/null",
            }
        )
        if extra_env:
            env.update(extra_env)

        process = subprocess.Popen(
            ["bash", str(SCRIPT_PATH)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )

        if send_signal is not None:
            self.wait_for_path(manifest_path)
            process.send_signal(send_signal)

        stdout, stderr = process.communicate(timeout=15)
        return process, stdout, stderr, manifest_path, log_dir

    def parse_log_path(self, stdout: str) -> Path:
        lines = [line.strip() for line in stdout.splitlines() if line.strip()]
        self.assertTrue(lines, "expected wrapper output to include the log path")
        return Path(lines[-1])

    def test_success_exits_zero_and_prints_log_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            process, stdout, stderr, _manifest_path, _log_dir = self.run_script(
                Path(tmp_dir),
                mode="success",
                lane="monitor-daemon-success",
            )

            self.assertEqual(process.returncode, 0, stdout + stderr)
            self.assertEqual(stderr, "")
            self.assertIn("fake daemon exited cleanly", stdout)
            log_path = self.parse_log_path(stdout)
            self.assertTrue(log_path.is_file())
            self.assertIn("fake daemon exited cleanly", log_path.read_text(encoding="utf-8"))

    def test_interrupt_cleanup_exits_zero_and_clears_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            process, stdout, stderr, manifest_path, _log_dir = self.run_script(
                Path(tmp_dir),
                mode="interrupt-cleans",
                lane="monitor-daemon-interrupt",
                send_signal=signal.SIGINT,
            )

            self.assertEqual(process.returncode, 0, stdout + stderr)
            self.assertEqual(stderr, "")
            self.assertFalse(manifest_path.exists(), "manifest should be removed on clean interrupt")
            self.assertIn("fake daemon cleaned manifest on interrupt", stdout)
            log_path = self.parse_log_path(stdout)
            self.assertTrue(log_path.is_file())

    def test_supervisor_uses_new_session_and_process_group_forwarding(self) -> None:
        script = SUPERVISOR_PATH.read_text(encoding="utf-8")

        self.assertIn("start_new_session=True", script)
        self.assertIn("os.killpg(process.pid, signum)", script)

    def test_interrupt_leak_fails_loudly_and_keeps_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            process, stdout, stderr, manifest_path, _log_dir = self.run_script(
                Path(tmp_dir),
                mode="interrupt-leaks",
                lane="monitor-daemon-leak",
                send_signal=signal.SIGINT,
            )

            self.assertEqual(process.returncode, 1, stdout + stderr)
            self.assertTrue(manifest_path.exists(), "manifest should remain when cleanup times out")
            self.assertIn("daemon interrupt cleanup timed out", stderr)
            log_path = self.parse_log_path(stdout)
            self.assertTrue(log_path.is_file())

    def test_non_interrupt_failure_propagates_child_status(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            process, stdout, stderr, _manifest_path, _log_dir = self.run_script(
                Path(tmp_dir),
                mode="fail",
                lane="monitor-daemon-fail",
            )

            self.assertEqual(process.returncode, 23, stdout + stderr)
            self.assertEqual(stderr, "")
            self.assertIn("fake daemon failed", stdout)
            log_path = self.parse_log_path(stdout)
            self.assertTrue(log_path.is_file())
            self.assertIn("fake daemon failed", log_path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
