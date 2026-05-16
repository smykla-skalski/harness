from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

from pty_test_support import collect_until_exit, read_until, spawn_in_pty


APP_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = APP_ROOT / "Scripts" / "run-bridge-start.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class RunBridgeStartScriptTests(unittest.TestCase):
    def write_fake_harness(self, path: Path, mode: str) -> None:
        content = """#!/usr/bin/env bash
set -euo pipefail

mode="__MODE__"

if [[ "${1:-}" != "bridge" || "${2:-}" != "start" ]]; then
  printf 'unexpected args: %s\\n' "$*" >&2
  exit 64
fi

case "$mode" in
  success)
    printf 'fake bridge exited cleanly\\n'
    exit 0
    ;;
  fail)
    printf 'fake bridge failed\\n' >&2
    exit 23
    ;;
  interrupt-cleans)
    printf 'fake bridge started\\n'
    trap 'printf "fake bridge cleaned up on interrupt\\n"; exit 130' INT TERM HUP
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

    def script_env(self, temp_root: Path, *, mode: str, lane: str) -> tuple[dict[str, str], Path]:
        fake_harness = temp_root / f"fake-bridge-{mode}.sh"
        self.write_fake_harness(fake_harness, mode)

        home_dir = temp_root / f"home-{lane}"
        home_dir.mkdir(parents=True, exist_ok=True)
        log_dir = temp_root / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)

        env = os.environ.copy()
        env.update(
            {
                "HOME": str(home_dir),
                "HARNESS_MONITOR_RUNTIME_LANE": lane,
                "HARNESS_MONITOR_BRIDGE_START_BIN": str(fake_harness),
                "HARNESS_MONITOR_BRIDGE_START_LOG_DIR": str(log_dir),
                "TMPDIR": str(temp_root),
                "BASH_ENV": "/dev/null",
            }
        )
        return env, log_dir

    def parse_log_path(self, stdout: str) -> Path:
        lines = [line.strip() for line in stdout.splitlines() if line.strip()]
        self.assertTrue(lines, "expected wrapper output to include the log path")
        return Path(lines[-1])

    def test_success_exits_zero_and_prints_log_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            env, _log_dir = self.script_env(
                Path(tmp_dir),
                mode="success",
                lane="monitor-bridge-success",
            )

            process = subprocess.run(
                ["bash", str(SCRIPT_PATH)],
                capture_output=True,
                text=True,
                env=env,
                check=False,
            )

            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
            self.assertEqual(process.stderr, "")
            self.assertIn("fake bridge exited cleanly", process.stdout)
            log_path = self.parse_log_path(process.stdout)
            self.assertTrue(log_path.is_file())
            self.assertIn("fake bridge exited cleanly", log_path.read_text(encoding="utf-8"))

    def test_ctrl_c_from_tty_exits_zero_and_prints_log_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            env, _log_dir = self.script_env(
                Path(tmp_dir),
                mode="interrupt-cleans",
                lane="monitor-bridge-tty-interrupt",
            )
            pid, master_fd = spawn_in_pty(["bash", str(SCRIPT_PATH)], env)
            try:
                output = read_until(master_fd, "fake bridge started")
                os.write(master_fd, b"\x03")
                exit_code, tail = collect_until_exit(pid, master_fd)
            finally:
                os.close(master_fd)

            combined_output = output + tail
            self.assertEqual(exit_code, 0, combined_output)
            self.assertIn("fake bridge cleaned up on interrupt", combined_output)
            log_path = self.parse_log_path(combined_output)
            self.assertTrue(log_path.is_file())
            log_text = log_path.read_text(encoding="utf-8")
            self.assertIn("fake bridge started", log_text)
            self.assertIn("fake bridge cleaned up on interrupt", log_text)

    def test_non_interrupt_failure_propagates_child_status(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            env, _log_dir = self.script_env(
                Path(tmp_dir),
                mode="fail",
                lane="monitor-bridge-fail",
            )

            process = subprocess.run(
                ["bash", str(SCRIPT_PATH)],
                capture_output=True,
                text=True,
                env=env,
                check=False,
            )

            self.assertEqual(process.returncode, 23, process.stdout + process.stderr)
            self.assertEqual(process.stderr, "")
            self.assertIn("fake bridge failed", process.stdout)
            log_path = self.parse_log_path(process.stdout)
            self.assertTrue(log_path.is_file())
            self.assertIn("fake bridge failed", log_path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
