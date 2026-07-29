from __future__ import annotations

import os
import platform
import shlex
import socket
import struct
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from typing import Iterable

SOL_LOCAL = 0
LOCAL_PEERPID = 2
SO_PEERCRED = 17


def _canonical_socket_path(path: str | Path) -> Path:
    candidate = str(path).removesuffix(" type=STREAM").removesuffix(" (deleted)")
    return Path(os.path.realpath(candidate))


def _path_is_under(path: str, root: Path) -> bool:
    try:
        resolved_candidate = _canonical_socket_path(path)
        resolved_root = Path(os.path.realpath(root))
        return resolved_candidate.is_relative_to(resolved_root)
    except (OSError, ValueError):
        return False


def _darwin_socket_owners(root: Path) -> dict[int, tuple[str, ...]]:
    try:
        completed = subprocess.run(
            ("/usr/sbin/lsof", "-nP", "-U", "-Fpn"),
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        return {}
    if completed.returncode != 0:
        return {}
    owners: dict[int, list[str]] = defaultdict(list)
    current_pid: int | None = None
    for line in completed.stdout.splitlines():
        if line.startswith("p") and line[1:].isdigit():
            current_pid = int(line[1:])
        elif line.startswith("n") and current_pid is not None:
            path = line[1:]
            if _path_is_under(path, root):
                owners[current_pid].append(path)
    return {pid: tuple(paths) for pid, paths in owners.items()}


def _linux_socket_inodes(
    root: Path,
    unix_table: Path = Path("/proc/net/unix"),
) -> dict[str, str]:
    sockets: dict[str, str] = {}
    try:
        lines = unix_table.read_text().splitlines()[1:]
    except OSError:
        return sockets
    for line in lines:
        fields = line.split(maxsplit=7)
        if len(fields) == 8 and _path_is_under(fields[7], root):
            sockets[fields[6]] = fields[7]
    return sockets


def _linux_socket_owners(
    root: Path,
    proc_root: Path = Path("/proc"),
) -> dict[int, tuple[str, ...]]:
    inodes = _linux_socket_inodes(root, proc_root / "net" / "unix")
    if not inodes:
        return {}
    owners: dict[int, list[str]] = defaultdict(list)
    for process_dir in proc_root.glob("[0-9]*"):
        try:
            pid = int(process_dir.name)
            descriptors = tuple((process_dir / "fd").iterdir())
        except (OSError, ValueError):
            continue
        for descriptor in descriptors:
            try:
                target = os.readlink(descriptor)
            except OSError:
                continue
            if not target.startswith("socket:[") or not target.endswith("]"):
                continue
            inode = target[8:-1]
            if path := inodes.get(inode):
                owners[pid].append(path)
    return {pid: tuple(paths) for pid, paths in owners.items()}


def socket_owners_under(root: Path) -> dict[int, tuple[str, ...]]:
    root = Path(os.path.abspath(root))
    host = platform.system()
    if host == "Darwin":
        return _darwin_socket_owners(root)
    if host == "Linux":
        return _linux_socket_owners(root)
    return {}


def pids_for_socket(path: Path) -> tuple[int, ...]:
    target = _canonical_socket_path(path)
    owners = socket_owners_under(path.parent)
    return tuple(
        pid
        for pid, paths in owners.items()
        if any(_canonical_socket_path(owned) == target for owned in paths)
    )


def sccache_socket_roots(configured: Path) -> tuple[Path, ...]:
    runtime_root = (
        configured.parent.parent
        if configured.parent.name.startswith("harness-sccache")
        else configured.parent
    )
    return tuple(sorted({Path("/tmp"), runtime_root}))


def peer_pid(path: str | Path) -> tuple[str, int | None]:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(0.5)
    try:
        client.connect(str(path))
        if sys.platform == "darwin":
            raw = client.getsockopt(SOL_LOCAL, LOCAL_PEERPID, struct.calcsize("i"))
        elif sys.platform.startswith("linux"):
            raw = client.getsockopt(
                socket.SOL_SOCKET,
                SO_PEERCRED,
                struct.calcsize("3i"),
            )
        else:
            return "unknown", None
    except (ConnectionRefusedError, FileNotFoundError):
        return "absent", None
    except OSError:
        return "unknown", None
    finally:
        client.close()
    values = struct.unpack("i" if sys.platform == "darwin" else "3i", raw)
    return "live", values[0]


def process_command(pid: int) -> str:
    completed = subprocess.run(
        ("/bin/ps", "-ww", "-p", str(pid), "-o", "command="),
        check=False,
        capture_output=True,
        text=True,
    )
    return completed.stdout.strip() if completed.returncode == 0 else ""


def is_sccache_server_command(command: str) -> bool:
    try:
        arguments = shlex.split(command)
    except ValueError:
        return False
    return len(arguments) == 1 and Path(arguments[0]).name == "sccache"


def _print_pids(pids: Iterable[int]) -> None:
    for pid in sorted(set(pids)):
        print(pid)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", type=Path, required=True)
    arguments = parser.parse_args()
    _print_pids(pids_for_socket(arguments.socket))
