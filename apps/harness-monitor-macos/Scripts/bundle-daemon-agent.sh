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

repo_root="$(resolve_repo_root)"
cd "$repo_root"

target_dir="$(resolve_cargo_target_dir)"
configuration="${CONFIGURATION:-Debug}"
profile_dir="debug"
cargo_args=(rustc --bin harness)
daemon_info_plist="$PROJECT_DIR/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist"

if [ "$configuration" = "Release" ]; then
  profile_dir="release"
  cargo_args+=(--release)
fi

find_cargo() {
  if [ -n "${CARGO_BIN:-}" ] && [ -x "$CARGO_BIN" ]; then
    printf '%s\n' "$CARGO_BIN"
    return
  fi

  if command -v cargo >/dev/null 2>&1; then
    command -v cargo
    return
  fi

  for candidate in \
    "$HOME/.cargo/bin/cargo" \
    /opt/homebrew/bin/cargo \
    /usr/local/bin/cargo; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  printf 'cargo is required to bundle the Harness daemon helper. Set CARGO_BIN or HARNESS_MONITOR_DAEMON_BINARY.\n' >&2
  exit 1
}

daemon_source="${HARNESS_MONITOR_DAEMON_BINARY:-}"
if [ -z "$daemon_source" ]; then
  daemon_source="$target_dir/$profile_dir/harness"
  cargo_bin="$(find_cargo)"
  daemon_info_digest="$(/usr/bin/shasum -a 256 "$daemon_info_plist" | /usr/bin/awk '{print $1}')"
  daemon_info_link_plist="$target_dir/daemon-info/io.harnessmonitor.daemon.$daemon_info_digest.Info.plist"
  /bin/mkdir -p "$(dirname "$daemon_info_link_plist")"
  /bin/cp "$daemon_info_plist" "$daemon_info_link_plist"
  if [ -n "${MARKETING_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${MARKETING_VERSION}" "$daemon_info_link_plist"
  fi
  CARGO_TARGET_DIR="$target_dir" "$cargo_bin" "${cargo_args[@]}" -- \
    -C "link-arg=-Wl,-sectcreate,__TEXT,__info_plist,$daemon_info_link_plist"
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

/bin/mkdir -p "$helpers_dir" "$launch_agents_dir"
/bin/cp "$daemon_source" "$daemon_target"
/bin/chmod 755 "$daemon_target"
/usr/bin/xattr -dr com.apple.provenance "$daemon_target" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.quarantine "$daemon_target" 2>/dev/null || true
/bin/cp "$PROJECT_DIR/Resources/LaunchAgents/io.harnessmonitor.daemon.plist" "$plist_target"
/usr/bin/plutil -lint "$plist_target"

if ! /usr/bin/otool -l "$daemon_target" | /usr/bin/grep -q "__info_plist"; then
  printf 'Harness daemon helper is missing embedded Info.plist metadata: %s\n' "$daemon_target" >&2
  exit 1
fi

package_version="$(resolve_package_version)"
validate_package_version "$package_version" "${MARKETING_VERSION:-}"

if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] \
  && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] \
  && [ "${EXPANDED_CODE_SIGN_IDENTITY:-}" != "-" ]; then
  /usr/bin/codesign \
    --force \
    --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    --options runtime \
    --timestamp \
    --identifier io.harnessmonitor.daemon \
    --entitlements "$PROJECT_DIR/HarnessMonitorDaemon.entitlements" \
    "$daemon_target"
  /usr/bin/codesign --verify --verbose=2 "$daemon_target"
fi
