#!/bin/bash
set -euo pipefail

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$ROOT/../.." && pwd)}"
XCODEGEN_BIN="${XCODEGEN_BIN:-$(command -v xcodegen || true)}"
BUILD_SERVER_VERSION="1.3.0"

if [ "${HARNESS_MONITOR_SKIP_VERSION_SYNC:-0}" != "1" ]; then
  "$REPO_ROOT/scripts/version.sh" sync-monitor
fi

if [ -z "${XCODEGEN_BIN}" ]; then
  echo "xcodegen is required on PATH or via XCODEGEN_BIN" >&2
  exit 1
fi

"$XCODEGEN_BIN" generate --spec "$ROOT/project.yml" --project "$ROOT"

PBXPROJ="$ROOT/HarnessMonitor.xcodeproj/project.pbxproj"
SCHEMES_DIR="$ROOT/HarnessMonitor.xcodeproj/xcshareddata/xcschemes"

# XcodeGen does not expose LastUpgradeCheck or product bundle file-reference names.
# Apply these as post-generation patches so they survive regeneration.

# Xcode 26 compatibility version (1430 = Xcode 14.3, 2640 = Xcode 26.0)
sed -i '' 's/LastUpgradeCheck = 1430/LastUpgradeCheck = 2640/g' "$PBXPROJ"

# Product bundle names: XcodeGen derives them from the target name, not PRODUCT_NAME.
# The shipped app and UI test host have display names with spaces; fix the file references.
sed -i '' \
  -e 's|/\* HarnessMonitor\.app \*/|/* Harness Monitor.app */|g' \
  -e 's|path = HarnessMonitor\.app;|path = "Harness Monitor.app";|g' \
  -e 's|/\* HarnessMonitorUITestHost\.app \*/|/* Harness Monitor UI Testing.app */|g' \
  -e 's|path = HarnessMonitorUITestHost\.app;|path = "Harness Monitor UI Testing.app";|g' \
  "$PBXPROJ"

# Scheme files carry the same LastUpgradeVersion attribute.
for scheme in "$SCHEMES_DIR"/*.xcscheme; do
  sed -i '' 's/LastUpgradeVersion = "1430"/LastUpgradeVersion = "2640"/g' "$scheme"
done

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
  "HarnessMonitor.xcodeproj/project.xcworkspace" \
  "../../tmp/xcode-derived"

write_build_server_config \
  "$REPO_ROOT/buildServer.json" \
  "./apps/harness-monitor-macos/Scripts/run-xcode-build-server.sh" \
  "apps/harness-monitor-macos/HarnessMonitor.xcodeproj/project.xcworkspace" \
  "tmp/xcode-derived"
