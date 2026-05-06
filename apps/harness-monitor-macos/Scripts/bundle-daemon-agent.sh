#!/bin/bash
set -euo pipefail

if [ "${XCODE_RUNNING_FOR_PREVIEWS:-}" = "1" ] || [[ "${BUILD_DIR:-}" == *"/Previews/"* ]]; then
  exit 0
fi

if [ "${HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE:-}" = "1" ]; then
  exit 0
fi

is_test_bundle_target() {
  [ -n "${TEST_TARGET_NAME:-}" ] || [ "${WRAPPER_EXTENSION:-}" = "xctest" ]
}

is_ui_test_host_target() {
  [ "${TARGET_NAME:-}" = "HarnessMonitorUITestHost" ] \
    || [ "${FULL_PRODUCT_NAME:-}" = "Harness Monitor UI Testing.app" ] \
    || [ "${WRAPPER_NAME:-}" = "Harness Monitor UI Testing.app" ]
}

if [ "${ACTION:-}" = "test" ] || is_test_bundle_target; then
  if [ "${HARNESS_MONITOR_FORCE_DAEMON_AGENT_BUNDLE_DURING_TESTS:-0}" != "1" ]; then
    exit 0
  fi
fi

if is_ui_test_host_target; then
  if [ "${HARNESS_MONITOR_FORCE_DAEMON_AGENT_BUNDLE_FOR_UI_TEST_HOST:-0}" != "1" ]; then
    exit 0
  fi
fi

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# Shared helpers keep path selection testable without executing the bundle flow.
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/daemon-bundle-env.sh
source "$SCRIPT_DIR/lib/daemon-bundle-env.sh"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/monitor-lanes.sh
source "$SCRIPT_DIR/lib/monitor-lanes.sh"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/daemon-cargo-build.sh
source "$SCRIPT_DIR/lib/daemon-cargo-build.sh"

repo_root="$(resolve_repo_root)"
harness_monitor_apply_runtime_lane_environment "$repo_root"

daemon_source="${HARNESS_MONITOR_DAEMON_BINARY:-}"
if [ -z "$daemon_source" ]; then
  daemon_source="$(daemon_binary_output_path)"
  if [ ! -x "$daemon_source" ]; then
    daemon_source="$(build_daemon_binary | /usr/bin/tail -n 1)"
  fi
fi

if [ ! -x "$daemon_source" ]; then
  printf 'Harness daemon binary is not executable: %s\n' "$daemon_source" >&2
  exit 1
fi

resolve_package_version() {
  /usr/bin/awk '
    /^\[package\]$/ { in_package = 1; next }
    /^\[/ && in_package { exit }
    in_package && $1 == "version" {
      gsub(/"/, "", $3)
      print $3
      exit
    }
  ' "$repo_root/Cargo.toml"
}

validate_package_version() {
  local package_version="$1"
  local expected_version="$2"

  if [ -z "$expected_version" ]; then
    return
  fi

  if [ -z "$package_version" ]; then
    printf 'Unable to determine Harness package version from %s\n' "$repo_root/Cargo.toml" >&2
    exit 1
  fi

  if [ "$package_version" != "$expected_version" ]; then
    printf \
      'Harness daemon helper version mismatch: package version is %s but app expects %s\n' \
      "$package_version" \
      "$expected_version" \
      >&2
    exit 1
  fi
}

helpers_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
launch_agents_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Library/LaunchAgents"
daemon_target="$helpers_dir/harness"
plist_target="$launch_agents_dir/io.harnessmonitor.daemon.plist"
launch_agent_label="$(harness_monitor_runtime_launch_agent_label "$repo_root")"
app_group_id="$(harness_monitor_runtime_app_group_id)"

/bin/mkdir -p "$helpers_dir" "$launch_agents_dir"
# `cp -p` preserves the linker-signed cs_mtime alignment from
# `target/debug/harness` (rustc/lld embeds an ad-hoc CodeDirectory whose
# cs_mtime is captured at link time). Plain `cp` updates the destination
# mtime to NOW, which leaves cs_mtime in the embedded signature
# pointing at link-time — kernel page validation then rejects the
# launch with "cs_mtime != mtime" (SIGKILL CODESIGNING) before our
# resign step below has a chance to run, racing against `launchctl
# kickstart` retries while the daemon is being rebuilt.
/bin/cp -p "$daemon_source" "$daemon_target"
/bin/chmod 755 "$daemon_target"
/usr/bin/xattr -dr com.apple.provenance "$daemon_target" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.quarantine "$daemon_target" 2>/dev/null || true
/bin/cp "$PROJECT_DIR/Resources/LaunchAgents/io.harnessmonitor.daemon.plist" "$plist_target"
/usr/bin/plutil -replace Label -string "$launch_agent_label" "$plist_target"
/usr/bin/plutil -replace EnvironmentVariables.HARNESS_APP_GROUP_ID -string "$app_group_id" "$plist_target"
if [[ -n "${HARNESS_DAEMON_DATA_HOME:-}" ]]; then
  /usr/bin/plutil -replace EnvironmentVariables.HARNESS_DAEMON_DATA_HOME -string "$HARNESS_DAEMON_DATA_HOME" "$plist_target"
fi
if [[ -n "${HARNESS_CODEX_WS_PORT:-}" ]]; then
  /usr/bin/plutil -replace EnvironmentVariables.HARNESS_CODEX_WS_PORT -string "$HARNESS_CODEX_WS_PORT" "$plist_target"
fi
if [[ -n "${HARNESS_MONITOR_RUNTIME_LANE:-}" ]]; then
  /usr/bin/plutil -replace EnvironmentVariables.HARNESS_MONITOR_RUNTIME_LANE -string "$HARNESS_MONITOR_RUNTIME_LANE" "$plist_target"
fi
/usr/bin/plutil -lint "$plist_target"

if ! /usr/bin/otool -l "$daemon_target" | /usr/bin/grep -q "__info_plist"; then
  printf 'Harness daemon helper is missing embedded Info.plist metadata: %s\n' "$daemon_target" >&2
  exit 1
fi

package_version="$(resolve_package_version)"
validate_package_version "$package_version" "${MARKETING_VERSION:-}"

# Resolve a codesign identity. Xcode populates EXPANDED_CODE_SIGN_IDENTITY
# only when CODE_SIGNING_ALLOWED=YES; the `monitor:build` and named build
# lanes pass NO so Xcode skips the embedded-binary sign
# phase. Without a fallback the helper would carry only the linker
# ad-hoc signature (TeamIdentifier=not set), which Group Container
# access denies — daemon would either crash on `cs_mtime != mtime` or
# exit EX_CONFIG (78) on first sandbox file read. Falling back to the
# first Apple Development identity from the user's keychain mirrors
# what Xcode would have picked, gives the helper a Team-ID signature,
# and keeps the timestamp service out of the build path so EDR-driven
# DNS races (Falcon, Kandji) cannot stall codesign mid-bundle.
codesign_identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ -z "$codesign_identity" ] || [ "$codesign_identity" = "-" ]; then
  codesign_identity="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -F'"' '/Apple Development:/ { print $2; exit }')"
fi

if [ -n "$codesign_identity" ]; then
  # Xcode-driven Release lanes provide a real timestamp via env;
  # local debug lanes opt out so codesign never blocks on the network.
  timestamp_flag="${HARNESS_DAEMON_CODESIGN_TIMESTAMP:---timestamp=none}"
  /usr/bin/codesign \
    --force \
    --sign "$codesign_identity" \
    --options runtime \
    "$timestamp_flag" \
    --identifier io.harnessmonitor.daemon \
    --entitlements "$PROJECT_DIR/HarnessMonitorDaemon.entitlements" \
    "$daemon_target"
  /usr/bin/codesign --verify --verbose=2 "$daemon_target"
else
  # No usable identity (CI without keychain). Refresh the ad-hoc
  # signature so cs_mtime aligns with the post-cp file mtime, giving
  # launchd at least a chance to spawn the helper in degraded mode.
  /usr/bin/codesign \
    --force \
    --sign - \
    --identifier io.harnessmonitor.daemon \
    "$daemon_target"
fi
