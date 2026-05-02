#!/bin/bash
set -euo pipefail

ROOT="${HARNESS_MONITOR_APP_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$ROOT/../.." && pwd)}"
BUILD_SERVER_VERSION="1.3.0"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/swift-tool-env.sh
source "$ROOT/Scripts/lib/swift-tool-env.sh"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/non-indexable-roots.sh
source "$ROOT/Scripts/lib/non-indexable-roots.sh"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/runtime-profile.sh
source "$ROOT/Scripts/lib/runtime-profile.sh"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/xcode-version.sh
source "$ROOT/Scripts/lib/xcode-version.sh"
sanitize_xcode_only_swift_environment

DERIVED_DATA_PATH="${XCODEBUILD_DERIVED_DATA_PATH:-$(harness_monitor_runtime_derived_data_path "$REPO_ROOT" "xcode-derived")}"
export XCODEBUILD_DERIVED_DATA_PATH="$DERIVED_DATA_PATH"
harness_monitor_apply_runtime_profile_environment

build_server_build_root_for_app_root() {
  if [[ "$DERIVED_DATA_PATH" == "$REPO_ROOT/"* ]]; then
    printf '../../%s\n' "${DERIVED_DATA_PATH#"$REPO_ROOT"/}"
    return 0
  fi
  printf '%s\n' "$DERIVED_DATA_PATH"
}

build_server_build_root_for_repo_root() {
  if [[ "$DERIVED_DATA_PATH" == "$REPO_ROOT/"* ]]; then
    printf '%s\n' "${DERIVED_DATA_PATH#"$REPO_ROOT"/}"
    return 0
  fi
  printf '%s\n' "$DERIVED_DATA_PATH"
}

write_build_server_config() {
  local config_path="$1"
  local argv_path="$2"
  local workspace_path="$3"
  local build_root_path="$4"

  cat > "$config_path" <<EOF
{
  "name": "xcode build server",
  "version": "${BUILD_SERVER_VERSION}",
  "bspVersion": "2.2.0",
  "languages": [
    "c",
    "cpp",
    "objective-c",
    "objective-cpp",
    "swift"
  ],
  "argv": [
    "/bin/bash",
    "${argv_path}"
  ],
  "workspace": "${workspace_path}",
  "build_root": "${build_root_path}",
  "scheme": "HarnessMonitor",
  "kind": "xcode"
}
EOF
}

seed_generated_app_entitlements() {
  local project_temp_dir="$1"

  PROJECT_TEMP_DIR="$project_temp_dir" /bin/bash "$ROOT/Scripts/prepare-app-entitlements.sh"
}

write_build_server_config \
  "$ROOT/buildServer.json" \
  "./Scripts/run-xcode-build-server.sh" \
  "HarnessMonitor.xcworkspace" \
  "$(build_server_build_root_for_app_root)"

write_build_server_config \
  "$REPO_ROOT/buildServer.json" \
  "./apps/harness-monitor-macos/Scripts/run-xcode-build-server.sh" \
  "apps/harness-monitor-macos/HarnessMonitor.xcworkspace" \
  "$(build_server_build_root_for_repo_root)"

ensure_monitor_build_artifact_roots_non_indexable "$REPO_ROOT"
ensure_non_indexable_directory "$DERIVED_DATA_PATH"

harness_monitor_write_workspace_settings \
  "$ROOT/HarnessMonitor.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings" \
  "$DERIVED_DATA_PATH"

harness_monitor_write_workspace_settings \
  "$ROOT/HarnessMonitor.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings" \
  "$DERIVED_DATA_PATH"

USER_DERIVED_DATA_PATH="$(harness_monitor_saved_user_derived_data_path "$ROOT" || true)"
if [[ -n "$USER_DERIVED_DATA_PATH" ]]; then
  harness_monitor_restore_saved_user_workspace_settings "$ROOT"
  ensure_non_indexable_directory "$USER_DERIVED_DATA_PATH"
  seed_generated_app_entitlements \
    "$USER_DERIVED_DATA_PATH/Build/Intermediates.noindex/HarnessMonitor.build"
fi

seed_generated_app_entitlements \
  "$DERIVED_DATA_PATH/Build/Intermediates.noindex/HarnessMonitor.build"

PBXPROJ="$ROOT/HarnessMonitor.xcodeproj/project.pbxproj"
DEFAULT_LAST_UPGRADE_CHECK="$(harness_monitor_default_xcode_upgrade_check)"
LAST_UPGRADE_CHECK="${HARNESS_MONITOR_LAST_UPGRADE_CHECK:-$DEFAULT_LAST_UPGRADE_CHECK}"
LAST_SWIFT_UPDATE_CHECK="${HARNESS_MONITOR_LAST_SWIFT_UPDATE_CHECK:-$LAST_UPGRADE_CHECK}"
PROJECT_OBJECT_VERSION="${HARNESS_MONITOR_PROJECT_OBJECT_VERSION:-77}"
PREFERRED_PROJECT_OBJECT_VERSION="${HARNESS_MONITOR_PREFERRED_PROJECT_OBJECT_VERSION:-$PROJECT_OBJECT_VERSION}"

# Tuist 4 / XcodeProj still serializes an Xcode 14-era PBX project
# (`objectVersion = 55;`, `compatibilityVersion = "Xcode 14.0";`) and omits
# `LastUpgradeCheck`, `LastSwiftUpdateCheck`, and project-object metadata.
# Normalize the generated pbxproj in one place after every `tuist generate`,
# using active Xcode's DTXcode value so patch releases do not bring back the
# "Update to Recommended Settings" banner.
if [ -f "$PBXPROJ" ]; then
  CANONICAL_VERSION="$("$REPO_ROOT/scripts/version.sh" show)"
  HARNESS_MONITOR_PBXPROJ="$PBXPROJ" \
  HARNESS_MONITOR_LAST_UPGRADE_CHECK="$LAST_UPGRADE_CHECK" \
  HARNESS_MONITOR_LAST_SWIFT_UPDATE_CHECK="$LAST_SWIFT_UPDATE_CHECK" \
  HARNESS_MONITOR_PROJECT_OBJECT_VERSION="$PROJECT_OBJECT_VERSION" \
  HARNESS_MONITOR_PREFERRED_PROJECT_OBJECT_VERSION="$PREFERRED_PROJECT_OBJECT_VERSION" \
  HARNESS_MONITOR_MARKETING_VERSION="$CANONICAL_VERSION" \
  HARNESS_MONITOR_CURRENT_PROJECT_VERSION="$CANONICAL_VERSION" \
  HARNESS_MONITOR_APP_ROOT="$ROOT" \
  HARNESS_MONITOR_REPO_ROOT="$REPO_ROOT" \
    /usr/bin/python3 "$ROOT/Scripts/patch-tuist-pbxproj.py"
fi

if [ "${HARNESS_MONITOR_SKIP_VERSION_SYNC:-0}" != "1" ]; then
  "$REPO_ROOT/scripts/version.sh" sync-monitor
fi
