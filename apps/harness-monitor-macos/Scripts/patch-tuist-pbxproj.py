#!/usr/bin/env python3
"""Patch Tuist's openstep pbxproj so Xcode does not nag with the
"Update to Recommended Settings" dialog.

Inserts:
- `LastUpgradeCheck = <value>;` on the PBXProject `attributes` block.
- `ProvisioningStyle = Automatic;` and `DevelopmentTeam = <id>;` for every
  PBXNativeTarget that owns signing-relevant settings (apps, app extensions,
  unit / UI test bundles).

Tuist 4 does not expose these via its DSL. The text is edited in place so the
file stays in the openstep ASCII format Xcode and SourceKit expect.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

SIGNING_PRODUCT_TYPES = frozenset(
    {
        '"com.apple.product-type.application"',
        '"com.apple.product-type.app-extension"',
        '"com.apple.product-type.bundle.unit-test"',
        '"com.apple.product-type.bundle.ui-testing"',
    }
)

NATIVE_TARGET_RE = re.compile(
    r"\t\t([0-9A-F]{24}) /\* [^*]*?\*/ = \{\n"
    r"\t\t\tisa = PBXNativeTarget;\n"
    r"((?:\t\t\t[^\n]*\n)*)"
    r"\t\t\};"
)
PRODUCT_TYPE_RE = re.compile(r'^\t\t\tproductType = ("[^"]+");$', re.MULTILINE)

ATTRIBUTES_BLOCK_RE = re.compile(
    r"(\t\t\tattributes = \{\n)((?:\t\t\t\t[^\n]*\n)*?)(\t\t\t\};)"
)

TARGET_ATTRIBUTES_RE = re.compile(
    r"(\t\t\t\tTargetAttributes = \{\n)((?:\t{4,}[^\n]*\n)*?)(\t\t\t\t\};)"
)

TARGET_ENTRY_RE = re.compile(
    r"\t{5}([0-9A-F]{24}) = \{\n((?:\t{6}[^\n]*\n)*?)\t{5}\};"
)


def find_signing_target_ids(text: str) -> list[str]:
    target_ids: list[str] = []
    for target_id, body in NATIVE_TARGET_RE.findall(text):
        product_type_match = PRODUCT_TYPE_RE.search(body)
        if product_type_match and product_type_match.group(1) in SIGNING_PRODUCT_TYPES:
            target_ids.append(target_id)
    return target_ids


def upsert_last_upgrade_check(text: str, value: str) -> str:
    def replace(match: re.Match[str]) -> str:
        head, body, tail = match.group(1), match.group(2), match.group(3)
        if "LastUpgradeCheck" in body:
            body = re.sub(
                r"LastUpgradeCheck = [^;]+;",
                f"LastUpgradeCheck = {value};",
                body,
            )
            return head + body + tail
        body = body.rstrip("\n") + "\n" if body and not body.endswith("\n") else body
        return head + body + f"\t\t\t\tLastUpgradeCheck = {value};\n" + tail

    return ATTRIBUTES_BLOCK_RE.sub(replace, text, count=1)


def upsert_target_entry(body: str, target_id: str, team: str) -> str:
    pattern = re.compile(
        rf"(\t{{5}}{target_id} = \{{\n)((?:\t{{6}}[^\n]*\n)*?)(\t{{5}}\}};)"
    )

    def add_lines(entry_body: str) -> str:
        if "ProvisioningStyle" not in entry_body:
            entry_body += "\t\t\t\t\tProvisioningStyle = Automatic;\n"
        if "DevelopmentTeam" not in entry_body:
            entry_body += f"\t\t\t\t\tDevelopmentTeam = {team};\n"
        return entry_body

    if pattern.search(body):
        return pattern.sub(lambda match: match.group(1) + add_lines(match.group(2)) + match.group(3), body)

    new_entry = (
        f"\t\t\t\t\t{target_id} = {{\n"
        f"\t\t\t\t\t\tDevelopmentTeam = {team};\n"
        f"\t\t\t\t\t\tProvisioningStyle = Automatic;\n"
        f"\t\t\t\t\t}};\n"
    )
    return body + new_entry


def upsert_target_attributes(text: str, target_ids: list[str], team: str) -> str:
    if TARGET_ATTRIBUTES_RE.search(text):
        def replace(match: re.Match[str]) -> str:
            head, body, tail = match.group(1), match.group(2), match.group(3)
            for target_id in target_ids:
                body = upsert_target_entry(body, target_id, team)
            return head + body + tail

        return TARGET_ATTRIBUTES_RE.sub(replace, text, count=1)

    entries = []
    for target_id in target_ids:
        entries.append(
            f"\t\t\t\t\t{target_id} = {{\n"
            f"\t\t\t\t\t\tDevelopmentTeam = {team};\n"
            f"\t\t\t\t\t\tProvisioningStyle = Automatic;\n"
            f"\t\t\t\t\t}};\n"
        )
    block = "\t\t\t\tTargetAttributes = {\n" + "".join(entries) + "\t\t\t\t};\n"

    def insert(match: re.Match[str]) -> str:
        head, body, tail = match.group(1), match.group(2), match.group(3)
        return head + body + block + tail

    return ATTRIBUTES_BLOCK_RE.sub(insert, text, count=1)


def patch_pbxproj(
    pbxproj_path: Path,
    last_upgrade: str,
    development_team: str | None,
) -> None:
    text = pbxproj_path.read_text()
    text = upsert_last_upgrade_check(text, last_upgrade)
    if development_team is not None:
        target_ids = find_signing_target_ids(text)
        if target_ids:
            text = upsert_target_attributes(text, target_ids, development_team)
    pbxproj_path.write_text(text)


def main() -> int:
    main_pbxproj = Path(os.environ["HARNESS_MONITOR_PBXPROJ"])
    last_upgrade = os.environ["HARNESS_MONITOR_LAST_UPGRADE_CHECK"]
    development_team = os.environ["HARNESS_MONITOR_DEVELOPMENT_TEAM"]
    repo_root = Path(os.environ["HARNESS_MONITOR_REPO_ROOT"])

    patch_pbxproj(main_pbxproj, last_upgrade, development_team)

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
            patch_pbxproj(candidate, last_upgrade, development_team)

    return 0


if __name__ == "__main__":
    sys.exit(main())
