#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
import sqlite3
import sys
import time
from dataclasses import dataclass
from pathlib import Path


DEFAULT_INTERVAL_SECONDS = 2.0
LOCK_TIMEOUT_SECONDS = 5.0
SYNC_RETRY_TIMEOUT_SECONDS = 15.0


@dataclass(frozen=True)
class SnapshotSpec:
    name: str
    source_path: Path
    snapshot_path: Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--interval", type=float, default=DEFAULT_INTERVAL_SECONDS)
    parser.add_argument("--once", action="store_true")
    return parser.parse_args()


def env_path(name: str, default: str) -> Path:
    value = os.getenv(name)
    return Path(value).expanduser() if value else Path(default)


def build_snapshot_specs() -> list[SnapshotSpec]:
    return [
        SnapshotSpec(
            name="daemon",
            source_path=env_path(
                "HARNESS_SQLITE_SOURCE_DAEMON_DB_PATH",
                "/srv/source/daemon/harness.db",
            ),
            snapshot_path=env_path(
                "HARNESS_SQLITE_SNAPSHOT_DAEMON_DB_PATH",
                "/srv/sqlite/daemon/harness.db",
            ),
        ),
        SnapshotSpec(
            name="monitor",
            source_path=env_path(
                "HARNESS_SQLITE_SOURCE_MONITOR_DB_PATH",
                "/srv/source/monitor/harness-cache.store",
            ),
            snapshot_path=env_path(
                "HARNESS_SQLITE_SNAPSHOT_MONITOR_DB_PATH",
                "/srv/sqlite/monitor/harness-cache.store",
            ),
        ),
    ]


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def remove_transient_snapshot_files(snapshot_path: Path) -> None:
    for suffix in ("-shm", "-wal"):
        transient_path = snapshot_path.parent / f"{snapshot_path.name}{suffix}"
        transient_path.unlink(missing_ok=True)


def clear_snapshot(spec: SnapshotSpec) -> None:
    spec.snapshot_path.unlink(missing_ok=True)
    remove_transient_snapshot_files(spec.snapshot_path)


def open_source_connection(source_path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(
        f"file:{source_path}?mode=ro",
        uri=True,
        timeout=LOCK_TIMEOUT_SECONDS,
    )
    connection.execute(f"PRAGMA busy_timeout = {int(LOCK_TIMEOUT_SECONDS * 1000)}")
    return connection


def backup_snapshot(spec: SnapshotSpec) -> None:
    spec.snapshot_path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = spec.snapshot_path.with_name(f".{spec.snapshot_path.name}.tmp")
    temp_path.unlink(missing_ok=True)
    deadline = time.monotonic() + SYNC_RETRY_TIMEOUT_SECONDS

    while True:
        try:
            with open_source_connection(spec.source_path) as source_connection:
                with sqlite3.connect(temp_path) as snapshot_connection:
                    source_connection.backup(snapshot_connection)
                    snapshot_connection.commit()
            with sqlite3.connect(temp_path) as snapshot_connection:
                snapshot_connection.execute("PRAGMA journal_mode=DELETE")
                snapshot_connection.execute("PRAGMA synchronous=NORMAL")
                snapshot_connection.commit()
            os.replace(temp_path, spec.snapshot_path)
            os.chmod(spec.snapshot_path, 0o644)
            remove_transient_snapshot_files(spec.snapshot_path)
            return
        except sqlite3.OperationalError as error:
            temp_path.unlink(missing_ok=True)
            if "locked" not in str(error).lower() or time.monotonic() >= deadline:
                raise
            time.sleep(0.2)


def sync_once(specs: list[SnapshotSpec]) -> None:
    for spec in specs:
        if not spec.source_path.is_file():
            clear_snapshot(spec)
            continue
        backup_snapshot(spec)


def run(args: argparse.Namespace) -> int:
    specs = build_snapshot_specs()
    if args.once:
        sync_once(specs)
        return 0

    while True:
        try:
            sync_once(specs)
        except Exception as error:  # noqa: BLE001
            log(f"sqlite snapshot sync failed: {error}")
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(run(parse_args()))
