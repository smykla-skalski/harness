#!/usr/bin/env python3
from __future__ import annotations

import os
import re
import socket
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_ROOT = Path(__file__).resolve().parent
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))
from lib.sccache_processes import (
    is_sccache_server_command,
    pids_for_socket,
    process_command,
    sccache_socket_roots,
    socket_owners_under,
)


ROOT = SCRIPT_ROOT.parent


def _configured_wrapper() -> str:
    config = ROOT / ".cargo" / "config.toml"
    try:
        text = config.read_text(encoding="utf-8")
    except OSError:
        return "unavailable"
    match = re.search(r'^\s*rustc-wrapper\s*=\s*"([^"]+)"', text, re.MULTILINE)
    return match.group(1) if match else "unconfigured"


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


def _socket_accepts(path: Path) -> bool:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(0.2)
    try:
        client.connect(str(path))
    except OSError:
        return False
    finally:
        client.close()
    return True


def _stats(binary: str, uds: str) -> tuple[dict[str, str], str]:
    completed = subprocess.run(
        (binary, "--show-stats"),
        check=False,
        capture_output=True,
        env={**os.environ, "SCCACHE_SERVER_UDS": uds},
        text=True,
    )
    if completed.returncode != 0:
        return {}, completed.stderr.strip() or "query failed"
    values: dict[str, str] = {}
    for line in completed.stdout.splitlines():
        match = re.match(r"^(.+?)\s{2,}(.+?)\s*$", line)
        if match:
            values[match.group(1)] = match.group(2)
    return values, "ok"


def _integer(values: dict[str, str], key: str) -> int:
    raw = values.get(key, "0").split()[0]
    try:
        return int(raw)
    except ValueError:
        return 0


def _cache_paths(values: dict[str, str]) -> tuple[Path, ...]:
    location = values.get("Cache location", "")
    quoted = re.search(r'"([^"]+)"', location)
    candidates = []
    if quoted:
        candidates.append(Path(quoted.group(1)))
    candidates.extend(
        (
            Path.home() / "Library" / "Caches" / "Mozilla.sccache",
            Path.home() / "Library" / "Caches" / "sccache",
            Path.home() / ".cache" / "sccache",
        )
    )
    result = []
    seen = set()
    for candidate in candidates:
        if not candidate.exists():
            continue
        resolved = candidate.resolve()
        if resolved not in seen:
            seen.add(resolved)
            result.append(resolved)
    return tuple(result)


def _size_kb(paths: tuple[Path, ...]) -> int:
    total = 0
    for path in paths:
        completed = subprocess.run(
            ("du", "-sk", str(path)),
            check=False,
            capture_output=True,
            text=True,
        )
        if completed.returncode == 0:
            try:
                total += int(completed.stdout.split()[0])
            except (IndexError, ValueError):
                pass
    return total


def _birth(paths: tuple[Path, ...]) -> str:
    if not paths:
        return "unavailable"
    timestamps = []
    for path in paths:
        stat = path.stat()
        timestamps.append(getattr(stat, "st_birthtime", stat.st_ctime))
    return datetime.fromtimestamp(min(timestamps), timezone.utc).isoformat()


def _normalized(path: str) -> str:
    return path.removesuffix(" type=STREAM").removesuffix(" (deleted)")


def _server_inventory(configured: Path) -> tuple[str, int, int, tuple[str, ...]]:
    owners: dict[int, set[str]] = {}
    for root in sccache_socket_roots(configured):
        for pid, paths in socket_owners_under(root).items():
            owners.setdefault(pid, set()).update(_normalized(path) for path in paths)
    server_paths = {
        pid: {
            path
            for path in paths
            if Path(path).parent.name.startswith("harness-sccache")
        }
        for pid, paths in owners.items()
        if is_sccache_server_command(process_command(pid))
    }
    server_paths = {pid: paths for pid, paths in server_paths.items() if paths}
    configured_pids = set(server_paths) & set(pids_for_socket(configured))
    orphan_pids = set(server_paths) - configured_pids
    orphan_paths = tuple(
        sorted(path for pid in orphan_pids for path in server_paths[pid])
    )
    supported = (
        sys.platform.startswith("linux")
        or (sys.platform == "darwin" and Path("/usr/sbin/lsof").exists())
    )
    return (
        "available" if supported else "unavailable",
        len(configured_pids),
        len(orphan_pids),
        orphan_paths,
    )


def main() -> int:
    try:
        environment = _cargo_environment()
    except RuntimeError as error:
        print(f"sccache_status=unavailable\nreason={error}")
        return 1
    binary = environment.get("SCCACHE_BIN", "")
    uds = environment.get("SCCACHE_SERVER_UDS", "")
    print(f"cache_mode={environment.get('CACHE_MODE', 'unknown')}")
    print(f"rustc_wrapper_config={_configured_wrapper()}")
    print(f"rustc_wrapper_env={environment.get('RUSTC_WRAPPER', '') or 'unset'}")
    print(f"configured_socket={uds or 'unavailable'}")
    if not binary or not uds:
        print("sccache_status=disabled")
        return 0

    configured = Path(uds)
    reachable = _socket_accepts(configured)
    values, stats_outcome = _stats(binary, uds) if reachable else ({}, "socket unreachable")
    inventory, live_count, orphan_count, orphan_paths = _server_inventory(configured)
    requests = _integer(values, "Compile requests")
    hits = _integer(values, "Cache hits")
    misses = _integer(values, "Cache misses")
    non_cacheable = _integer(values, "Non-cacheable calls")
    hit_rate = 100 * hits / max(1, hits + misses)
    if orphan_count:
        state = "leaking"
    elif not reachable:
        state = "unavailable"
    elif misses >= 20 and hit_rate < 5:
        state = "cold"
    else:
        state = "healthy"
    paths = _cache_paths(values)

    print(f"sccache_status={state}")
    print(f"socket_reachable={'yes' if reachable else 'no'}")
    print(f"stats_query={stats_outcome}")
    print(f"compile_requests={requests}")
    print(f"cache_hits={hits}")
    print(f"cache_misses={misses}")
    print(f"cache_hit_rate={hit_rate:.2f}%")
    print(f"non_cacheable_calls={non_cacheable}")
    print(f"cache_paths={','.join(str(path) for path in paths) or 'unavailable'}")
    print(f"cache_birth={_birth(paths)}")
    print(f"cache_size_kb={_size_kb(paths)}")
    print(f"socket_inventory={inventory}")
    print(f"live_servers={live_count}")
    print(f"orphan_servers={orphan_count}")
    if orphan_paths:
        print(f"orphan_sockets={','.join(orphan_paths)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
