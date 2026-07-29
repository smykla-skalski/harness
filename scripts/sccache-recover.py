#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import select
import signal
import socket
import struct
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

SCRIPT_ROOT = Path(__file__).resolve().parent
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))
from lib.sccache_processes import (
    is_sccache_server_command,
    pids_for_socket,
    process_command,
    socket_owners_under,
)

ROOT = SCRIPT_ROOT.parent
SOL_LOCAL = 0
LOCAL_PEERPID = 2
SO_PEERCRED = 17


@dataclass(frozen=True)
class Owner:
    pid: int
    sockets: tuple[str, ...]
    command: str
    action: str


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Stop proven orphan servers; the default is a dry-run.",
    )
    return parser.parse_args()


def _cargo_environment() -> dict[str, str]:
    completed = subprocess.run(
        (str(ROOT / "scripts" / "cargo-local.sh"), "--print-env"),
        check=False,
        capture_output=True,
        cwd=ROOT,
        text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            completed.stderr.strip() or "scripts/cargo-local.sh --print-env failed"
        )
    return dict(
        line.split("=", maxsplit=1)
        for line in completed.stdout.splitlines()
        if "=" in line
    )


def _normalized(path: str) -> str:
    return path.removesuffix(" type=STREAM").removesuffix(" (deleted)")


def _peer_pid(path: str) -> tuple[str, int | None]:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(0.5)
    try:
        client.connect(path)
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


def _owners(configured: Path) -> tuple[Owner, ...]:
    roots = {Path("/tmp"), configured.parent}
    owned: dict[int, set[str]] = {}
    for root in roots:
        for pid, paths in socket_owners_under(root).items():
            owned.setdefault(pid, set()).update(_normalized(path) for path in paths)
    socket_paths = {
        path
        for paths in owned.values()
        for path in paths
        if Path(path).parent.name.startswith("harness-sccache")
    }
    states = {path: _peer_pid(path) for path in socket_paths}
    result = []
    for pid, paths in sorted(owned.items()):
        relevant = tuple(sorted(set(paths) & socket_paths))
        if not relevant:
            continue
        command = process_command(pid)
        if not is_sccache_server_command(command):
            action = "keep-client"
        elif any(states[path] == ("live", pid) for path in relevant):
            action = "keep-live"
        elif any(states[path][0] == "unknown" for path in relevant):
            action = "keep-unknown"
        else:
            action = "stop-orphan"
        result.append(Owner(pid, relevant, command, action))
    return tuple(result)


def _terminate(owner: Owner) -> str:
    if (
        process_command(owner.pid) != owner.command
        or not is_sccache_server_command(owner.command)
    ):
        return "identity-changed"
    if not any(owner.pid in pids_for_socket(Path(path)) for path in owner.sockets):
        return "ownership-lost"
    watch: tuple[str, object] | None = None
    if sys.platform == "darwin":
        queue = select.kqueue()
        try:
            queue.control(
                [
                    select.kevent(
                        owner.pid,
                        filter=select.KQ_FILTER_PROC,
                        flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                        fflags=select.KQ_NOTE_EXIT,
                    )
                ],
                0,
                0,
            )
            watch = ("kqueue", queue)
        except OSError:
            queue.close()
    elif sys.platform.startswith("linux") and hasattr(os, "pidfd_open"):
        try:
            watch = ("pidfd", os.pidfd_open(owner.pid))
        except OSError:
            pass
    try:
        os.kill(owner.pid, signal.SIGTERM)
    except ProcessLookupError:
        return "already-exited"
    if watch is None:
        return "signal-sent"
    kind, descriptor = watch
    if kind == "kqueue":
        queue = descriptor
        try:
            return "stopped" if queue.control(None, 1, 2) else "still-running"
        finally:
            queue.close()
    ready, _, _ = select.select((descriptor,), (), (), 2)
    os.close(descriptor)
    return "stopped" if ready else "still-running"


def main() -> int:
    arguments = _arguments()
    try:
        environment = _cargo_environment()
    except RuntimeError as error:
        print(f"sccache recovery unavailable: {error}", file=sys.stderr)
        return 1
    configured = environment.get("SCCACHE_SERVER_UDS", "")
    if not configured:
        print("sccache recovery unavailable: configured socket is missing", file=sys.stderr)
        return 1
    print(f"configured_socket={configured}")
    print(f"mode={'apply' if arguments.apply else 'dry-run'}")
    owners = _owners(Path(configured))
    for owner in owners:
        sockets = ",".join(owner.sockets)
        if owner.action != "stop-orphan":
            outcome = owner.action
        elif arguments.apply:
            outcome = _terminate(owner)
        else:
            outcome = "would-stop-orphan"
        print(f"pid={owner.pid} action={outcome} sockets={sockets}")
    print(
        "summary="
        f"owners:{len(owners)},"
        f"orphans:{sum(owner.action == 'stop-orphan' for owner in owners)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
