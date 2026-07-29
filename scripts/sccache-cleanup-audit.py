#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fcntl
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path


RETENTION = 100


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--cache-path", action="append", default=[])
    parser.add_argument("--size-kb", type=int, required=True)
    parser.add_argument("--reason", required=True)
    parser.add_argument("--threshold-kb", type=int, required=True)
    parser.add_argument("--server-socket", default="")
    parser.add_argument("--server-pid", action="append", default=[])
    parser.add_argument("--stop-outcome", required=True)
    parser.add_argument("--preview", action="store_true")
    return parser.parse_args()


def _event(arguments: argparse.Namespace) -> dict[str, object]:
    server_pids = [int(pid) for pid in arguments.server_pid]
    if server_pids:
        server_identity = "pid-identified"
    elif arguments.server_socket:
        server_identity = "pid-unavailable"
    else:
        server_identity = "socket-unavailable"
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "mode": arguments.mode,
        "cache_paths": arguments.cache_path,
        "measured_size_kb": arguments.size_kb,
        "reason": arguments.reason,
        "threshold_kb": arguments.threshold_kb,
        "server_socket": arguments.server_socket or None,
        "server_identity": server_identity,
        "server_pids": server_pids,
        "stop_outcome": arguments.stop_outcome,
    }


def _write_bounded(log_path: Path, encoded: str) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = log_path.with_suffix(f"{log_path.suffix}.lock")
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            prior = log_path.read_text(encoding="utf-8").splitlines()
        except FileNotFoundError:
            prior = []
        lines = [*prior[-(RETENTION - 1) :], encoded]
        descriptor, staged_name = tempfile.mkstemp(
            dir=log_path.parent,
            prefix=f".{log_path.name}.",
        )
        staged = Path(staged_name)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write("\n".join(lines))
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(staged, log_path)
            directory = os.open(log_path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            staged.unlink(missing_ok=True)


def main() -> int:
    arguments = _arguments()
    encoded = json.dumps(_event(arguments), separators=(",", ":"), sort_keys=True)
    if arguments.preview:
        print(encoded)
        return 0
    _write_bounded(arguments.log, encoded)
    print(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
