from __future__ import annotations

import errno
import os
import pty
import select
import time


def spawn_in_pty(argv: list[str], env: dict[str, str]) -> tuple[int, int]:
    pid, master_fd = pty.fork()
    if pid == 0:
        os.execvpe(argv[0], argv, env)
    return pid, master_fd


def read_until(master_fd: int, needle: str, timeout_seconds: float = 5.0) -> str:
    deadline = time.monotonic() + timeout_seconds
    chunks = bytearray()
    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        ready, _, _ = select.select([master_fd], [], [], remaining)
        if not ready:
            continue
        try:
            chunk = os.read(master_fd, 4096)
        except OSError as error:
            if error.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        chunks.extend(chunk)
        text = chunks.decode("utf-8", errors="replace")
        if needle in text:
            return text
    text = chunks.decode("utf-8", errors="replace")
    raise AssertionError(f"timed out waiting for {needle!r}; output so far:\n{text}")


def collect_until_exit(pid: int, master_fd: int, timeout_seconds: float = 15.0) -> tuple[int, str]:
    deadline = time.monotonic() + timeout_seconds
    chunks = bytearray()
    while time.monotonic() < deadline:
        waited_pid, status = os.waitpid(pid, os.WNOHANG)
        if waited_pid == pid:
            while True:
                ready, _, _ = select.select([master_fd], [], [], 0)
                if not ready:
                    break
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                chunks.extend(chunk)
            return os.waitstatus_to_exitcode(status), chunks.decode("utf-8", errors="replace")

        ready, _, _ = select.select([master_fd], [], [], 0.1)
        if not ready:
            continue
        try:
            chunk = os.read(master_fd, 4096)
        except OSError as error:
            if error.errno == errno.EIO:
                continue
            raise
        if not chunk:
            continue
        chunks.extend(chunk)

    raise AssertionError(
        "timed out waiting for PTY child to exit; output so far:\n"
        + chunks.decode("utf-8", errors="replace")
    )
