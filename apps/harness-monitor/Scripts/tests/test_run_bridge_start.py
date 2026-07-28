from __future__ import annotations

import os
import signal
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
    def write_fake_bridge(self, path: Path, mode: str) -> None:
        content = """#!/usr/bin/env bash
set -euo pipefail

mode="__MODE__"

if [[ "${1:-}" != "start" || "${2:-}" != "" ]]; then
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
  orphan-self-exit)
    # Record our pid (== pgid, we are the session leader) so the test can
    # SIGKILL the whole group afterwards instead of leaking the grandchild.
    printf '%s\\n' "$$" > "${FAKE_BRIDGE_PGID_FILE:?}"
    printf 'fake bridge started\\n'
    # Leave a grandchild that inherits the stdout pipe, ignores the signals we
    # forward, and blocks on a real read (no timer) so it outlives us and holds
    # the pipe open with no EOF -- the condition that wedged pump.join. It reads
    # fd 3, a dup of our stdin the test keeps open: bash redirects a background
    # job's fd 0 to /dev/null, which would give an instant EOF, but not fd 3.
    exec 3<&0
    ( trap '' INT TERM HUP; IFS= read -r _ <&3 || true ) &
    printf 'fake bridge self-exited with a lingering grandchild\\n'
    exit 0
    ;;
  orphan-interrupt-cleans)
    # Install the trap before announcing readiness so a signal that arrives the
    # instant the test sees "started" always reaches the handler, not bash's
    # default disposition.
    trap 'printf "fake bridge cleaned up on interrupt\\n"; exit 130' INT TERM HUP
    printf '%s\\n' "$$" > "${FAKE_BRIDGE_PGID_FILE:?}"
    # A signal-ignoring grandchild that blocks on fd 3 (a dup of stdin the test
    # keeps open; see orphan-self-exit), keeping the stdout pipe open even after
    # we forward the interrupt to the group, so EOF never comes. On the buggy
    # wrapper this wedged pump.join and ctrl+c appeared ignored.
    exec 3<&0
    ( trap '' INT TERM HUP; IFS= read -r _ <&3 || true ) &
    printf 'fake bridge started\\n'
    # Block on the background job (interrupted by the forwarded signal) rather
    # than polling with sleep.
    wait
    ;;
  *)
    printf 'unknown fake mode: %s\\n' "$mode" >&2
    exit 64
    ;;
esac
"""
        write_executable(path, content.replace("__MODE__", mode))

    def script_env(self, temp_root: Path, *, mode: str, lane: str) -> tuple[dict[str, str], Path]:
        fake_bridge = temp_root / f"fake-bridge-{mode}.sh"
        self.write_fake_bridge(fake_bridge, mode)

        home_dir = temp_root / f"home-{lane}"
        home_dir.mkdir(parents=True, exist_ok=True)
        log_dir = temp_root / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)

        env = os.environ.copy()
        env.update(
            {
                "HOME": str(home_dir),
                "HARNESS_MONITOR_RUNTIME_LANE": lane,
                "HARNESS_MONITOR_BRIDGE_START_BIN": str(fake_bridge),
                "HARNESS_MONITOR_BRIDGE_START_LOG_DIR": str(log_dir),
                "FAKE_BRIDGE_PGID_FILE": str(temp_root / "fake-bridge-pgid"),
                "TMPDIR": str(temp_root),
                "BASH_ENV": "/dev/null",
            }
        )
        return env, log_dir

    def reap_orphan_group(self, env: dict[str, str]) -> None:
        """SIGKILL the fake bridge's process group so a signal-ignoring orphan
        that was holding the stdout pipe open cannot linger past the test."""
        pgid_path = Path(env["FAKE_BRIDGE_PGID_FILE"])
        try:
            pgid = int(pgid_path.read_text(encoding="utf-8").strip())
        except (OSError, ValueError):
            return
        try:
            os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

    def terminate_process(self, process: subprocess.Popen) -> None:
        """Close pipes and make sure the wrapper is reaped, killing it if it is
        still running (e.g. after a wedge caught by the timeout)."""
        for stream in (process.stdin, process.stdout):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass
        if process.poll() is None:
            process.kill()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass

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

    def test_self_exit_with_orphan_holding_pipe_does_not_wedge(self) -> None:
        """Regression: the child exits but leaves a signal-ignoring grandchild
        that inherited the stdout pipe and blocks reading a dup of stdin. A
        blocking read never sees EOF, so the wrapper used to wedge in pump.join
        for hours. It must reap the child and exit within the timeout, still
        capturing what the child wrote before exiting. A wedge shows up as
        TimeoutExpired.
        """
        with tempfile.TemporaryDirectory() as tmp_dir:
            env, _log_dir = self.script_env(
                Path(tmp_dir),
                mode="orphan-self-exit",
                lane="monitor-bridge-orphan-self-exit",
            )

            # A PIPE stdin the test holds open keeps the grandchild's read
            # blocked no matter what the test runner's own stdin is.
            process = subprocess.Popen(
                ["bash", str(SCRIPT_PATH)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                env=env,
            )
            try:
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.fail("wrapper wedged waiting on an orphaned pipe holder")
                stdout = process.stdout.read()
                self.assertEqual(process.returncode, 0, stdout)
                log_path = self.parse_log_path(stdout)
                self.assertIn("fake bridge self-exited", log_path.read_text(encoding="utf-8"))
            finally:
                self.reap_orphan_group(env)
                self.terminate_process(process)

    def test_ctrl_c_with_orphan_holding_pipe_does_not_wedge(self) -> None:
        """Regression: ctrl+c on a running bridge that has orphaned a
        signal-ignoring grandchild holding the stdout pipe. The child cleans up
        and exits, but the orphan keeps the pipe open past the forwarded signal.
        The wrapper must reap and exit instead of appearing to ignore ctrl+c
        while stuck in pump.join; a wedge shows up as a collect timeout.
        """
        with tempfile.TemporaryDirectory() as tmp_dir:
            env, _log_dir = self.script_env(
                Path(tmp_dir),
                mode="orphan-interrupt-cleans",
                lane="monitor-bridge-orphan-interrupt",
            )
            pid, master_fd = spawn_in_pty(["bash", str(SCRIPT_PATH)], env)
            try:
                output = read_until(master_fd, "fake bridge started")
                os.write(master_fd, b"\x03")
                exit_code, tail = collect_until_exit(pid, master_fd, timeout_seconds=5)
            finally:
                os.close(master_fd)
                self.reap_orphan_group(env)

            combined_output = output + tail
            self.assertEqual(exit_code, 0, combined_output)
            self.assertIn("fake bridge cleaned up on interrupt", combined_output)
            log_path = self.parse_log_path(combined_output)
            self.assertTrue(log_path.is_file())

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
