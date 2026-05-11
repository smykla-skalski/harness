#!/usr/bin/env python3
"""Run `harness daemon dev` under a signal-aware supervisor."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

ACCEPTED_INTERRUPT_STATUSES = frozenset({0, 129, 130, 143})
PROCESS_POLL_INTERVAL_SECONDS = 0.1
MANIFEST_CLEANUP_TIMEOUT_SECONDS = 5.0


def exit_status(returncode: int) -> int:
    return 128 + (-returncode) if returncode < 0 else returncode


def wait_for_process_exit(process: subprocess.Popen[bytes]) -> int:
    while True:
        try:
            return process.wait(timeout=PROCESS_POLL_INTERVAL_SECONDS)
        except subprocess.TimeoutExpired:
            continue


def wait_for_manifest_cleanup(manifest_path: Path) -> bool:
    deadline = time.monotonic() + MANIFEST_CLEANUP_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if not manifest_path.exists():
            return True
        time.sleep(PROCESS_POLL_INTERVAL_SECONDS)
    return not manifest_path.exists()


def pump_output(process: subprocess.Popen[bytes], log_file: object) -> threading.Thread:
    stdout_open = True

    def copy_output() -> None:
        nonlocal stdout_open

        assert process.stdout is not None
        stdout_fd = process.stdout.fileno()
        while True:
            try:
                chunk = os.read(stdout_fd, 8192)
            except InterruptedError:
                continue
            if not chunk:
                break
            if stdout_open:
                try:
                    os.write(sys.stdout.fileno(), chunk)
                except BrokenPipeError:
                    stdout_open = False
            log_file.write(chunk)
        process.stdout.close()

    thread = threading.Thread(target=copy_output, name="monitor-daemon-dev-log-pump")
    thread.start()
    return thread


def supervise(binary: Path, log_path: Path, manifest_path: Path) -> int:
    interrupted = threading.Event()

    with log_path.open("ab", buffering=0) as log_file:
        process = subprocess.Popen(
            [str(binary), "daemon", "dev"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )

        def forward_signal(signum: int, _frame: object) -> None:
            interrupted.set()
            try:
                os.killpg(process.pid, signum)
            except ProcessLookupError:
                pass

        for handled_signal in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(handled_signal, forward_signal)

        pump = pump_output(process, log_file)
        try:
            status = exit_status(wait_for_process_exit(process))
        finally:
            pump.join()

        if interrupted.is_set():
            if not wait_for_manifest_cleanup(manifest_path):
                print(
                    f"daemon interrupt cleanup timed out; manifest still present at {manifest_path}",
                    file=sys.stderr,
                )
                print(log_path)
                return 1
            if status in ACCEPTED_INTERRUPT_STATUSES:
                print(log_path)
                return 0

        print(log_path)
        return status


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(
            "usage: run-daemon-dev.py <harness-binary> <log-path> <manifest-path>",
            file=sys.stderr,
        )
        return 2

    binary = Path(argv[1])
    log_path = Path(argv[2])
    manifest_path = Path(argv[3])
    return supervise(binary, log_path, manifest_path)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
