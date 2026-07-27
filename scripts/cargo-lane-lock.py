#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fcntl
import json
import os
import shlex
import signal
import stat
import subprocess
import sys
import time
from pathlib import Path


EXIT_BUSY = 75
METADATA_RETRIES = 25
METADATA_RETRY_SECONDS = 0.01


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run one command while exclusively owning a Cargo target lane."
    )
    parser.add_argument("--lock-root", required=True, type=Path)
    parser.add_argument("--lock-key", required=True)
    parser.add_argument("--target-dir", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("a command is required after --")
    return args


def open_lock(lock_root: Path, lock_key: str) -> tuple[int, Path]:
    safe_characters = "._-"
    if not lock_key or any(
        not character.isalnum() and character not in safe_characters
        for character in lock_key
    ):
        raise ValueError("lock key contains an unsafe character")

    lock_root.mkdir(parents=True, exist_ok=True)
    if lock_root.is_symlink() or not lock_root.is_dir():
        raise ValueError(f"lock root must be a real directory: {lock_root}")

    lock_path = lock_root / f"{lock_key}.lock"
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(lock_path, flags, 0o600)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise ValueError(f"lane lock must be a regular file: {lock_path}")
    return fd, lock_path


def read_owner(fd: int) -> dict[str, object]:
    for _ in range(METADATA_RETRIES):
        try:
            payload = os.pread(fd, 64 * 1024, 0)
            owner = json.loads(payload.decode("utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            owner = {}
        if isinstance(owner, dict) and owner.get("pid") and owner.get("command"):
            return owner
        time.sleep(METADATA_RETRY_SECONDS)
    return {}


def report_busy(target_dir: str, owner: dict[str, object]) -> None:
    pid = owner.get("pid", "unknown")
    command = owner.get("command", "metadata not yet available")
    print("cargo-local: build lane is already in use", file=sys.stderr)
    print(f"  target: {target_dir}", file=sys.stderr)
    print(f"  owner PID: {pid}", file=sys.stderr)
    print(f"  owner command: {command}", file=sys.stderr)
    print(
        "Wait for that command to finish or use a different checkout/target lane.",
        file=sys.stderr,
    )


def write_owner(
    fd: int,
    target_dir: str,
    command: list[str],
    owner_pid: int,
) -> None:
    payload = json.dumps(
        {
            "pid": owner_pid,
            "command": shlex.join(command),
            "target": target_dir,
        },
        sort_keys=True,
    ).encode("utf-8")
    os.ftruncate(fd, 0)
    os.pwrite(fd, payload, 0)
    os.fsync(fd)


def run_owner(command: list[str], environment: dict[str, str], fd: int) -> int:
    process = subprocess.Popen(command, env=environment, close_fds=True)
    try:
        write_owner(fd, environment["CARGO_TARGET_DIR"], command, process.pid)
    except OSError:
        process.terminate()
        process.wait()
        raise

    def forward_signal(signum: int, _frame: object) -> None:
        if process.poll() is None:
            try:
                process.send_signal(signum)
            except ProcessLookupError:
                pass

    handled_signals = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
    previous_handlers = {
        signum: signal.signal(signum, forward_signal) for signum in handled_signals
    }
    try:
        return_code = process.wait()
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
    return return_code if return_code >= 0 else 128 - return_code


def main() -> int:
    args = parse_args()
    try:
        fd, _lock_path = open_lock(args.lock_root, args.lock_key)
    except (OSError, ValueError) as error:
        print(f"cargo-local: cannot prepare the build-lane lock: {error}", file=sys.stderr)
        return 70

    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            report_busy(args.target_dir, read_owner(fd))
            return EXIT_BUSY

        os.ftruncate(fd, 0)
        environment = os.environ.copy()
        environment["HARNESS_CARGO_LANE_LOCK_KEY"] = args.lock_key
        environment["HARNESS_CARGO_LANE_LOCK_SUPERVISOR_PID"] = str(os.getpid())
        environment["CARGO_TARGET_DIR"] = args.target_dir
        return run_owner(args.command, environment, fd)
    except OSError as error:
        print(f"cargo-local: cannot run the lane owner: {error}", file=sys.stderr)
        return 70
    finally:
        os.close(fd)


if __name__ == "__main__":
    raise SystemExit(main())
