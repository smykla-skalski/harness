#!/usr/bin/env python3
"""Run a long-lived harness command under a signal-aware log tee supervisor."""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import threading
import time
from collections.abc import Sequence
from pathlib import Path

PROCESS_POLL_INTERVAL_SECONDS = 0.1
DEFAULT_CLEANUP_TIMEOUT_SECONDS = 5.0


def parse_statuses(raw: str) -> frozenset[int]:
    values: set[int] = set()
    for part in raw.split(","):
        stripped = part.strip()
        if not stripped:
            continue
        try:
            values.add(int(stripped))
        except ValueError as error:
            raise argparse.ArgumentTypeError(
                f"invalid accepted interrupt status: {stripped}"
            ) from error
    if not values:
        raise argparse.ArgumentTypeError("accepted interrupt status list must not be empty")
    return frozenset(values)


def exit_status(returncode: int) -> int:
    return 128 + (-returncode) if returncode < 0 else returncode


def wait_for_process_exit(process: subprocess.Popen[bytes]) -> int:
    while True:
        try:
            return process.wait(timeout=PROCESS_POLL_INTERVAL_SECONDS)
        except subprocess.TimeoutExpired:
            continue


def wait_for_path_cleanup(path: Path, timeout_seconds: float) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if not path.exists():
            return True
        time.sleep(PROCESS_POLL_INTERVAL_SECONDS)
    return not path.exists()


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

    thread = threading.Thread(target=copy_output, name="monitor-harness-command-log-pump")
    thread.start()
    return thread


def install_signal_handlers(
    child_new_session: bool,
    process_ref: list[subprocess.Popen[bytes] | None],
    pending_signals: list[int],
    interrupted: threading.Event,
) -> None:
    def dispatch_signal(signum: int) -> None:
        process = process_ref[0]
        if process is None:
            pending_signals.append(signum)
            return
        try:
            if child_new_session:
                os.killpg(process.pid, signum)
            else:
                process.send_signal(signum)
        except PermissionError:
            try:
                process.send_signal(signum)
            except ProcessLookupError:
                pass
        except ProcessLookupError:
            pass

    def forward_signal(signum: int, _frame: object) -> None:
        interrupted.set()
        dispatch_signal(signum)

    for handled_signal in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(handled_signal, forward_signal)


def supervise(
    command: Sequence[str],
    *,
    log_path: Path,
    accepted_interrupt_statuses: frozenset[int],
    cleanup_path: Path | None,
    cleanup_description: str,
    cleanup_timeout_seconds: float,
    child_new_session: bool,
) -> int:
    interrupted = threading.Event()
    process_ref: list[subprocess.Popen[bytes] | None] = [None]
    pending_signals: list[int] = []
    install_signal_handlers(
        child_new_session=child_new_session,
        process_ref=process_ref,
        pending_signals=pending_signals,
        interrupted=interrupted,
    )

    with log_path.open("ab", buffering=0) as log_file:
        process = subprocess.Popen(
            list(command),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=child_new_session,
        )
        process_ref[0] = process
        while pending_signals:
            signum = pending_signals.pop(0)
            try:
                if child_new_session:
                    os.killpg(process.pid, signum)
                else:
                    process.send_signal(signum)
            except ProcessLookupError:
                break

        pump = pump_output(process, log_file)
        try:
            status = exit_status(wait_for_process_exit(process))
        finally:
            pump.join()

    if interrupted.is_set():
        if cleanup_path is not None and not wait_for_path_cleanup(
            cleanup_path, cleanup_timeout_seconds
        ):
            print(
                f"{cleanup_description} timed out; path still present at {cleanup_path}",
                file=sys.stderr,
            )
            print(log_path)
            return 1
        if status in accepted_interrupt_statuses:
            print(log_path)
            return 0

    print(log_path)
    return status


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="run-harness-command.py",
        description="Run a long-lived harness command with live log teeing and signal forwarding.",
    )
    parser.add_argument("--log", required=True, type=Path, dest="log_path")
    parser.add_argument(
        "--accepted-interrupt-statuses",
        default="0,129,130,143",
        type=parse_statuses,
        dest="accepted_interrupt_statuses",
    )
    parser.add_argument("--cleanup-path", type=Path)
    parser.add_argument(
        "--cleanup-description",
        default="interrupt cleanup",
    )
    parser.add_argument(
        "--cleanup-timeout-seconds",
        type=float,
        default=DEFAULT_CLEANUP_TIMEOUT_SECONDS,
    )
    parser.add_argument(
        "--child-new-session",
        action="store_true",
        help="spawn the child in a new session/process group and forward signals explicitly",
    )
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv[1:])
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command:
        parser.error("missing command to run")
    return args


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    return supervise(
        args.command,
        log_path=args.log_path,
        accepted_interrupt_statuses=args.accepted_interrupt_statuses,
        cleanup_path=args.cleanup_path,
        cleanup_description=args.cleanup_description,
        cleanup_timeout_seconds=args.cleanup_timeout_seconds,
        child_new_session=args.child_new_session,
    )


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
