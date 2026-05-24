#!/bin/bash
set -euo pipefail

ROOT="${HARNESS_MONITOR_APP_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$ROOT/../.." && pwd)}"
BUILD_SERVER_VERSION="1.3.0"
# shellcheck source=apps/harness-monitor/Scripts/lib/swift-tool-env.sh
source "$ROOT/Scripts/lib/swift-tool-env.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/non-indexable-roots.sh
source "$ROOT/Scripts/lib/non-indexable-roots.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/monitor-lanes.sh
source "$ROOT/Scripts/lib/monitor-lanes.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/xcode-version.sh
source "$ROOT/Scripts/lib/xcode-version.sh"
sanitize_xcode_only_swift_environment
harness_monitor_apply_runtime_lane_environment "$REPO_ROOT"

DERIVED_DATA_PATH="${XCODEBUILD_DERIVED_DATA_PATH:-$(harness_monitor_build_derived_data_path "$REPO_ROOT")}"
export XCODEBUILD_DERIVED_DATA_PATH="$DERIVED_DATA_PATH"
# Keep tracked buildServer configs stable even when an isolated build lane is
# active. Lane-specific DerivedData belongs in workspace settings and explicit
# CLI invocations, not in checked-in repo files.
BUILD_SERVER_DERIVED_DATA_PATH="$(harness_monitor_shared_derived_data_path "$REPO_ROOT")"

build_server_build_root_for_app_root() {
  if [[ "$BUILD_SERVER_DERIVED_DATA_PATH" == "$REPO_ROOT/"* ]]; then
    printf '../../%s\n' "${BUILD_SERVER_DERIVED_DATA_PATH#"$REPO_ROOT"/}"
    return 0
  fi
  printf '%s\n' "$BUILD_SERVER_DERIVED_DATA_PATH"
}

build_server_build_root_for_repo_root() {
  if [[ "$BUILD_SERVER_DERIVED_DATA_PATH" == "$REPO_ROOT/"* ]]; then
    printf '%s\n' "${BUILD_SERVER_DERIVED_DATA_PATH#"$REPO_ROOT"/}"
    return 0
  fi
  printf '%s\n' "$BUILD_SERVER_DERIVED_DATA_PATH"
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

patch_run_scheme_runtime_env() {
  # Intentionally a no-op. The Run scheme stays lane-agnostic so Xcode IDE
  # launches always go through cross-lane discovery in HarnessMonitorPaths.
  # Agents still pass HARNESS_MONITOR_RUNTIME_LANE on the xcodebuild command
  # line; that env propagates to the test/run process and overrides discovery.
  # Set HARNESS_MONITOR_PATCH_RUN_SCHEME=1 to opt back into the legacy patch.
  local scheme_path="$1"

  if [[ ! -f "$scheme_path" ]]; then
    return 0
  fi

  if [[ "${HARNESS_MONITOR_PATCH_RUN_SCHEME:-0}" != "1" ]]; then
    return 0
  fi

  /usr/bin/python3 "$ROOT/Scripts/patch-run-scheme-env.py" \
    "$scheme_path" \
    "HARNESS_MONITOR_RUNTIME_LANE=${HARNESS_MONITOR_RUNTIME_LANE}" \
    "HARNESS_DAEMON_DATA_HOME=${HARNESS_DAEMON_DATA_HOME}" \
    "HARNESS_CODEX_WS_PORT=${HARNESS_CODEX_WS_PORT}" \
    "HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL=${HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL}"
}

write_build_server_config \
  "$ROOT/buildServer.json" \
  "./Scripts/run-xcode-build-server.sh" \
  "HarnessMonitor.xcworkspace" \
  "$(build_server_build_root_for_app_root)"

write_build_server_config \
  "$REPO_ROOT/buildServer.json" \
  "./apps/harness-monitor/Scripts/run-xcode-build-server.sh" \
  "apps/harness-monitor/HarnessMonitor.xcworkspace" \
  "$(build_server_build_root_for_repo_root)"

ensure_monitor_build_artifact_roots_non_indexable "$REPO_ROOT"
ensure_non_indexable_directory "$DERIVED_DATA_PATH"

harness_monitor_write_workspace_settings \
  "$ROOT/HarnessMonitor.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings" \
  "$DERIVED_DATA_PATH"

harness_monitor_write_workspace_settings \
  "$ROOT/HarnessMonitor.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings" \
  "$DERIVED_DATA_PATH"

harness_monitor_write_user_workspace_settings "$ROOT" "$DERIVED_DATA_PATH"

seed_generated_app_entitlements \
  "$DERIVED_DATA_PATH/Build/Intermediates.noindex/HarnessMonitor.build"

patch_run_scheme_runtime_env \
  "$ROOT/HarnessMonitor.xcodeproj/xcshareddata/xcschemes/HarnessMonitor.xcscheme"
patch_run_scheme_runtime_env \
  "$ROOT/HarnessMonitor.xcodeproj/xcshareddata/xcschemes/HarnessMonitor (External Daemon).xcscheme"

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
