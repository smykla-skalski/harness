#!/usr/bin/env python3
"""Read `xcrun simctl runtime list -j` JSON on stdin; emit tab-separated
runtime UUIDs deemed stale.

Stale = any iOS or watchOS runtime whose major version is below 26 (one major
behind macOS 26 development), plus duplicate (platform, major) buckets where
the older build is kept around. Ordering inside a bucket prefers the entry
with the most recent `lastUsedAt` timestamp; everything older is dropped.

Output columns: runtime_uuid \\t platform \\t version \\t build \\t bytes \\t last_used
"""
from __future__ import annotations

import json
import sys


def main() -> int:
    data = json.load(sys.stdin)
    buckets: dict[tuple[str, str], list[tuple[str, str, str, str, int]]] = {}
    for rid, r in data.items():
        ver = r.get("version", "")
        major = ver.split(".")[0]
        plat = r.get("platformIdentifier", "")
        last = r.get("lastUsedAt") or ""
        buckets.setdefault((plat, major), []).append(
            (last, rid, ver, r.get("build", ""), int(r.get("sizeBytes", 0)))
        )

    to_delete: list[tuple[str, str, str, str, int]] = []
    for (plat, major), entries in buckets.items():
        if plat.endswith("iphonesimulator") and major.isdigit() and int(major) < 26:
            to_delete.extend(entries)
            continue
        if plat.endswith("watchsimulator") and major.isdigit() and int(major) < 26:
            to_delete.extend(entries)
            continue
        if len(entries) > 1:
            entries.sort()
            to_delete.extend(entries[:-1])

    for last, rid, ver, build, size in to_delete:
        plat = data[rid].get("platformIdentifier", "?").split(".")[-1]
        last_str = last if last else "never"
        print("\t".join([rid, plat, ver, build, str(size), last_str]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
