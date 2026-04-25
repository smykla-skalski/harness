#!/bin/bash
set -euo pipefail

ROOT="${HARNESS_MONITOR_APP_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$ROOT/../.." && pwd)}"
BUILD_SERVER_VERSION="1.3.0"

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

write_build_server_config \
  "$ROOT/buildServer.json" \
  "./Scripts/run-xcode-build-server.sh" \
  "HarnessMonitor.xcworkspace" \
  "../../xcode-derived"

write_build_server_config \
  "$REPO_ROOT/buildServer.json" \
  "./apps/harness-monitor-macos/Scripts/run-xcode-build-server.sh" \
  "apps/harness-monitor-macos/HarnessMonitor.xcworkspace" \
  "xcode-derived"

PBXPROJ="$ROOT/HarnessMonitor.xcodeproj/project.pbxproj"
DEVELOPMENT_TEAM_ID="${HARNESS_MONITOR_DEVELOPMENT_TEAM:-Q498EB36N4}"
LAST_UPGRADE_CHECK="${HARNESS_MONITOR_LAST_UPGRADE_CHECK:-2640}"

# Tuist 4 does not emit `LastUpgradeCheck` or per-target `TargetAttributes`
# (`ProvisioningStyle = Automatic;`, `DevelopmentTeam = ...;`). Without them
# Xcode shows "Update to Recommended Settings" on every open, and the proposed
# change rewrites CODE_SIGN_IDENTITY to the ad-hoc `-` which fails the
# `com.apple.developer.*` and app-group entitlements declared by the main app,
# the UI test host, and the preview host. Inject the same attributes XcodeGen
# used so the dialog stops appearing.
if [ -f "$PBXPROJ" ]; then
  HARNESS_MONITOR_PBXPROJ="$PBXPROJ" \
  HARNESS_MONITOR_LAST_UPGRADE_CHECK="$LAST_UPGRADE_CHECK" \
  HARNESS_MONITOR_DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_ID" \
  HARNESS_MONITOR_APP_ROOT="$ROOT" \
  HARNESS_MONITOR_REPO_ROOT="$REPO_ROOT" \
    /usr/bin/python3 "$ROOT/Scripts/patch-tuist-pbxproj.py"
fi

if [ "${HARNESS_MONITOR_SKIP_VERSION_SYNC:-0}" != "1" ]; then
  "$REPO_ROOT/scripts/version.sh" sync-monitor
fi
