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
- macOS app-target `SystemCapabilities` metadata for disabled App Groups, so
  Xcode does not keep re-suggesting "Enable Register App Groups".

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

PBX_NATIVE_TARGET_RE = re.compile(
    r"\t\t([0-9A-F]{24}) /\* ([^*]+) \*/ = \{\n"
    r"\t\t\tisa = PBXNativeTarget;\n"
    r"((?:\t\t\t[^\n]*\n)*?)"
    r"\t\t\};",
)

SYSTEM_CAPABILITIES_RE = re.compile(
    r"(\t\t\t\t\t\tSystemCapabilities = \{\n)((?:\t{7,}[^\n]*\n)*?)(\t\t\t\t\t\t\};)"
)

DISABLED_MAC_APP_GROUP_TARGETS = frozenset({"HarnessMonitor", "HarnessMonitorUITestHost"})
MAC_APP_GROUPS_CAPABILITY_KEY = "com.apple.ApplicationGroups.Mac"


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


def capability_entry(capability_key: str, enabled: int) -> str:
    return (
        f"\t\t\t\t\t\t\t{capability_key} = {{\n"
        f"\t\t\t\t\t\t\t\tenabled = {enabled};\n"
        f"\t\t\t\t\t\t\t}};\n"
    )


def upsert_system_capability(target_body: str, capability_key: str, enabled: int) -> str:
    entry = capability_entry(capability_key, enabled)
    capability_re = re.compile(
        rf"^\t{{7}}{re.escape(capability_key)} = \{{\n"
        rf"\t{{8}}enabled = [01];\n"
        rf"\t{{7}}\}};\n?",
        re.MULTILINE,
    )

    def replace(match: re.Match[str]) -> str:
        head, body, tail = match.group(1), match.group(2), match.group(3)
        if capability_re.search(body):
            body = capability_re.sub(entry, body, count=1)
        else:
            body = body.rstrip("\n") + "\n" if body and not body.endswith("\n") else body
            body += entry
        return head + body + tail

    if SYSTEM_CAPABILITIES_RE.search(target_body):
        return SYSTEM_CAPABILITIES_RE.sub(replace, target_body, count=1)

    body = target_body.rstrip("\n") + "\n" if target_body and not target_body.endswith("\n") else target_body
    return body + "\t\t\t\t\t\tSystemCapabilities = {\n" + entry + "\t\t\t\t\t\t};\n"


def native_target_ids(text: str, target_names: set[str]) -> dict[str, str]:
    target_ids: dict[str, str] = {}
    for match in PBX_NATIVE_TARGET_RE.finditer(text):
        target_id, target_name, body = match.group(1), match.group(2), match.group(3)
        if target_name not in target_names:
            continue
        if 'productType = "com.apple.product-type.application";' not in body:
            continue
        target_ids[target_name] = target_id
    return target_ids


def upsert_target_system_capability(
    text: str,
    *,
    target_id: str,
    capability_key: str,
    enabled: int,
) -> str:
    target_entry_re = re.compile(
        rf"(\t\t\t\t\t{target_id} = \{{\n)((?:\t{{6,}}[^\n]*\n)*?)(\t\t\t\t\t\}};\n)"
    )

    def replace_target(match: re.Match[str]) -> str:
        head, body, tail = match.group(1), match.group(2), match.group(3)
        return head + upsert_system_capability(body, capability_key, enabled) + tail

    updated, count = target_entry_re.subn(replace_target, text, count=1)
    if count:
        return updated

    target_entry = (
        f"\t\t\t\t\t{target_id} = {{\n"
        f"\t\t\t\t\t\tSystemCapabilities = {{\n"
        f"{capability_entry(capability_key, enabled)}"
        f"\t\t\t\t\t\t}};\n"
        f"\t\t\t\t\t}};\n"
    )

    def replace_target_attributes(match: re.Match[str]) -> str:
        head, body, tail = match.group(1), match.group(2), match.group(3)
        body = body.rstrip("\n") + "\n" if body and not body.endswith("\n") else body
        return head + body + target_entry + tail

    return TARGET_ATTRIBUTES_RE.sub(replace_target_attributes, text, count=1)


def upsert_disabled_mac_app_group_metadata(text: str) -> str:
    for target_id in native_target_ids(text, set(DISABLED_MAC_APP_GROUP_TARGETS)).values():
        text = upsert_target_system_capability(
            text,
            target_id=target_id,
            capability_key=MAC_APP_GROUPS_CAPABILITY_KEY,
            enabled=0,
        )
    return text


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
    text = upsert_disabled_mac_app_group_metadata(text)
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
