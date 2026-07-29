#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import select
import signal
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

SCRIPT_ROOT = Path(__file__).resolve().parent
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))
from lib.sccache_processes import (
    is_sccache_server_command,
    peer_pid,
    pids_for_socket,
    process_command,
    sccache_socket_roots,
    socket_owners_under,
)

ROOT = SCRIPT_ROOT.parent


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


def _owners(configured: Path) -> tuple[Owner, ...]:
    owned: dict[int, set[str]] = {}
    for root in sccache_socket_roots(configured):
        for pid, paths in socket_owners_under(root).items():
            owned.setdefault(pid, set()).update(_normalized(path) for path in paths)
    socket_paths = {
        path
        for paths in owned.values()
        for path in paths
        if Path(path).parent.name.startswith("harness-sccache")
    }
    states = {path: peer_pid(path) for path in socket_paths}
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
        try:
            os.kill(owner.pid, signal.SIGTERM)
        except ProcessLookupError:
            return "already-exited"
        if watch is None:
            return "signal-sent"
        kind, descriptor = watch
        if kind == "kqueue":
            return (
                "stopped"
                if descriptor.control(None, 1, 2)
                else "still-running"
            )
        ready, _, _ = select.select((descriptor,), (), (), 2)
        return "stopped" if ready else "still-running"
    finally:
        if watch is None:
            pass
        elif watch[0] == "kqueue":
            watch[1].close()
        else:
            os.close(watch[1])


def _outcome(owner: Owner, apply: bool) -> str:
    if owner.action != "stop-orphan":
        return owner.action
    if apply:
        return _terminate(owner)
    return "would-stop-orphan"


def _recovery_succeeded(outcome: str) -> bool:
    return outcome in {"stopped", "already-exited"}


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
    unresolved = 0
    for owner in owners:
        outcome = _outcome(owner, arguments.apply)
        if (
            arguments.apply
            and owner.action == "stop-orphan"
            and not _recovery_succeeded(outcome)
        ):
            unresolved += 1
        sockets = ",".join(owner.sockets)
        print(f"pid={owner.pid} action={outcome} sockets={sockets}")
    print(
        "summary="
        f"owners:{len(owners)},"
        f"orphans:{sum(owner.action == 'stop-orphan' for owner in owners)},"
        f"unresolved:{unresolved}"
    )
    return 1 if arguments.apply and unresolved else 0


if __name__ == "__main__":
    raise SystemExit(main())
