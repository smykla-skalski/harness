#!/usr/bin/env python3
"""Patch Tuist's openstep pbxproj so Xcode does not nag with the
"Update to Recommended Settings" dialog.

Normalizes:
- top-level `objectVersion = <value>;`.
- remove the stale PBXProject `compatibilityVersion = "Xcode 14.0";`.
- `preferredProjectObjectVersion = <value>;` on the PBXProject block.
- `LastUpgradeCheck = <value>;` and `LastSwiftUpdateCheck = <value>;`
  on the PBXProject `attributes` block.
- target-level `DevelopmentTeam` / `ProvisioningStyle` metadata from
  `TargetAttributes`, so targets inherit signing cleanly from project settings.

Tuist 4 does not expose the project-format fields via its DSL, and its
generator still hardcodes an Xcode 14-era object version. The text is edited
in place so the
file stays in the openstep ASCII format Xcode and SourceKit expect.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

PROJECT_OBJECT_VERSION_RE = re.compile(r"^(\tobjectVersion = )\d+;$", re.MULTILINE)

PBXPROJECT_BLOCK_RE = re.compile(
    r"(\t\t[0-9A-F]{24} /\* Project object \*/ = \{\n"
    r"\t\t\tisa = PBXProject;\n)"
    r"((?:\t\t\t[^\n]*\n)*)"
    r"(\t\t\};)"
)

ATTRIBUTES_BLOCK_RE = re.compile(
    r"(\t\t\tattributes = \{\n)((?:\t\t\t\t[^\n]*\n)*?)(\t\t\t\};)"
)

TARGET_ATTRIBUTES_RE = re.compile(
    r"(\t\t\t\tTargetAttributes = \{\n)((?:\t{4,}[^\n]*\n)*?)(\t\t\t\t\};)"
)


def upsert_project_attribute(text: str, key: str, value: str) -> str:
    def replace(match: re.Match[str]) -> str:
        head, body, tail = match.group(1), match.group(2), match.group(3)
        if key in body:
            body = re.sub(
                rf"{key} = [^;]+;",
                f"{key} = {value};",
                body,
            )
            return head + body + tail
        body = body.rstrip("\n") + "\n" if body and not body.endswith("\n") else body
        return head + body + f"\t\t\t\t{key} = {value};\n" + tail

    return ATTRIBUTES_BLOCK_RE.sub(replace, text, count=1)


def remove_project_key(body: str, key: str) -> str:
    return re.sub(rf"^\t\t\t{key} = [^;]+;\n", "", body, flags=re.MULTILINE)


def upsert_project_key(body: str, key: str, value: str, *, insert_after: str) -> str:
    line = f"\t\t\t{key} = {value};"
    existing = re.compile(rf"^\t\t\t{key} = [^;]+;$", re.MULTILINE)
    if existing.search(body):
        return existing.sub(line, body, count=1)

    anchor = re.compile(rf"^\t\t\t{insert_after} = [^;]+;$", re.MULTILINE)
    match = anchor.search(body)
    if match:
        return body[: match.end()] + f"\n{line}" + body[match.end() :]
    return body + line + "\n"


def normalize_project_format(
    text: str,
    *,
    object_version: str,
    preferred_project_object_version: str,
) -> str:
    text, _ = PROJECT_OBJECT_VERSION_RE.subn(
        rf"\g<1>{object_version};",
        text,
        count=1,
    )

    def replace(match: re.Match[str]) -> str:
        head, body, tail = match.group(1), match.group(2), match.group(3)
        body = remove_project_key(body, "compatibilityVersion")
        body = upsert_project_key(
            body,
            "preferredProjectObjectVersion",
            preferred_project_object_version,
            insert_after="mainGroup",
        )
        return head + body + tail

    return PBXPROJECT_BLOCK_RE.sub(replace, text, count=1)


def strip_target_attribute_signing_metadata(text: str) -> str:
    def replace(match: re.Match[str]) -> str:
        head, body, tail = match.group(1), match.group(2), match.group(3)
        body = re.sub(r"^\t{6}DevelopmentTeam = [^;]+;\n", "", body, flags=re.MULTILINE)
        body = re.sub(r"^\t{6}ProvisioningStyle = [^;]+;\n", "", body, flags=re.MULTILINE)
        return head + body + tail

    return TARGET_ATTRIBUTES_RE.sub(replace, text, count=1)


def patch_pbxproj(
    pbxproj_path: Path,
    last_upgrade: str,
    last_swift_update: str,
    object_version: str,
    preferred_project_object_version: str,
) -> None:
    text = pbxproj_path.read_text()
    text = normalize_project_format(
        text,
        object_version=object_version,
        preferred_project_object_version=preferred_project_object_version,
    )
    text = upsert_project_attribute(text, "LastSwiftUpdateCheck", last_swift_update)
    text = upsert_project_attribute(text, "LastUpgradeCheck", last_upgrade)
    text = strip_target_attribute_signing_metadata(text)
    pbxproj_path.write_text(text)


def main() -> int:
    main_pbxproj = Path(os.environ["HARNESS_MONITOR_PBXPROJ"])
    last_upgrade = os.environ["HARNESS_MONITOR_LAST_UPGRADE_CHECK"]
    last_swift_update = os.environ["HARNESS_MONITOR_LAST_SWIFT_UPDATE_CHECK"]
    object_version = os.environ["HARNESS_MONITOR_PROJECT_OBJECT_VERSION"]
    preferred_project_object_version = os.environ["HARNESS_MONITOR_PREFERRED_PROJECT_OBJECT_VERSION"]
    repo_root = Path(os.environ["HARNESS_MONITOR_REPO_ROOT"])

    patch_pbxproj(
        main_pbxproj,
        last_upgrade,
        last_swift_update,
        object_version,
        preferred_project_object_version,
    )

    # Tuist generates standalone xcodeprojs for external SPM packages it
    # materializes (HarnessMonitorRegistry under mcp-servers, opentelemetry,
    # grpc-swift, etc.). Each one defaults to `LastUpgradeCheck = 9999;`
    # which Xcode flags as "Update to recommended settings". Normalize them
    # to the same value as the main project and patch any app/test targets
    # those generated projects materialize so their TargetAttributes block
    # matches the same automatic-signing metadata Xcode expects.
    app_root = Path(os.environ.get("HARNESS_MONITOR_APP_ROOT", main_pbxproj.parents[1]))
    # Only patch xcodeprojs Tuist generates, not vendored package examples.
    # Tuist materializes external SPM packages into per-package xcodeprojs:
    # - the local registry SPM: mcp-servers/harness-monitor-registry/HarnessMonitorRegistry.xcodeproj
    # - remote SPM packages: <app>/Derived/<Package>/Project.xcodeproj
    extra_roots = [
        repo_root / "mcp-servers" / "harness-monitor-registry",
        app_root / "Derived",
    ]

    seen: set[Path] = {main_pbxproj.resolve()}
    for root in extra_roots:
        if not root.exists():
            continue
        for candidate in sorted(root.rglob("project.pbxproj")):
            resolved = candidate.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            patch_pbxproj(
                candidate,
                last_upgrade,
                last_swift_update,
                object_version,
                preferred_project_object_version,
            )

    return 0


if __name__ == "__main__":
    sys.exit(main())
