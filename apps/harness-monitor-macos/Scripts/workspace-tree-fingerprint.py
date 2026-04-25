#!/usr/bin/env python3
"""Emit the SHA-256 fingerprint of the Harness Monitor source surface.

Invoked from inject-build-provenance.sh. The fingerprint covers entitlements,
build scripts, and source trees so the Build Provenance plist changes whenever
any embedded artifact changes.
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path


VARIANT_INCLUDES = {
    "monitor-app": [
        "HarnessMonitor.entitlements",
        "HarnessMonitorDaemon.entitlements",
        "HarnessMonitor.xcodeproj/project.pbxproj",
        "Resources",
        "Scripts/bundle-daemon-agent.sh",
        "Scripts/run-xcode-build-server.sh",
        "Sources/HarnessMonitor",
        "Sources/HarnessMonitorKit",
        "Sources/HarnessMonitorUIPreviewable",
    ],
    "ui-test-host": [
        "HarnessMonitor.entitlements",
        "HarnessMonitorUITestHost.entitlements",
        "HarnessMonitorDaemon.entitlements",
        "HarnessMonitor.xcodeproj/project.pbxproj",
        "Resources",
        "Scripts/bundle-daemon-agent.sh",
        "Scripts/run-xcode-build-server.sh",
        "Sources/HarnessMonitor",
        "Sources/HarnessMonitorKit",
        "Sources/HarnessMonitorUIPreviewable",
    ],
}


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: workspace-tree-fingerprint.py <variant> <project-dir>", file=sys.stderr)
        return 64

    variant = sys.argv[1]
    project_dir = Path(sys.argv[2])

    includes = VARIANT_INCLUDES.get(variant)
    if includes is None:
        print(f"unknown variant: {variant}", file=sys.stderr)
        return 64

    digest = hashlib.sha256()
    for relative in includes:
        include_path = project_dir / relative
        if not include_path.exists():
            continue

        if include_path.is_file():
            file_paths = [include_path]
        else:
            file_paths = sorted(
                candidate for candidate in include_path.rglob("*") if candidate.is_file()
            )

        for file_path in file_paths:
            relative_path = file_path.relative_to(project_dir).as_posix()
            digest.update(relative_path.encode("utf-8"))
            digest.update(b"\0")
            with file_path.open("rb") as handle:
                for chunk in iter(lambda h=handle: h.read(1024 * 1024), b""):
                    digest.update(chunk)
            digest.update(b"\0")

    print(digest.hexdigest())
    return 0


if __name__ == "__main__":
    sys.exit(main())
