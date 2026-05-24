#!/bin/bash
set -euo pipefail

if [ "${XCODE_RUNNING_FOR_PREVIEWS:-}" = "1" ] || [[ "${BUILD_DIR:-}" == *"/Previews/"* ]]; then
  exit 0
fi

if [ "${HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE:-}" = "1" ]; then
  exit 0
fi

# Xcode fires `<BuildAction>` pre-actions during Clean (and may fire build
# phases under unusual configurations). Compiling and re-signing the daemon
# helper only to have its destination dir wiped wastes minutes.
case "${ACTION:-}" in
  clean|cleanBuild) exit 0 ;;
esac

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
# shellcheck source=apps/harness-monitor/Scripts/lib/daemon-bundle-env.sh
source "$SCRIPT_DIR/lib/daemon-bundle-env.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/monitor-lanes.sh
source "$SCRIPT_DIR/lib/monitor-lanes.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/daemon-cargo-build.sh
source "$SCRIPT_DIR/lib/daemon-cargo-build.sh"

repo_root="$(resolve_repo_root)"
harness_monitor_apply_runtime_lane_environment "$repo_root"

daemon_source="${HARNESS_MONITOR_DAEMON_BINARY:-}"
if [ -z "$daemon_source" ]; then
  daemon_source="$(resolve_daemon_binary_for_bundle "$repo_root")"
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

file_sha256() {
  local path="$1"
  if [ ! -f "$path" ]; then
    printf 'missing\n'
    return 0
  fi
  /usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{ print $1 }'
}

file_stat_signature() {
  local path="$1"
  if [ ! -e "$path" ]; then
    printf 'missing\n'
    return 0
  fi
  /usr/bin/stat -f '%m:%z' "$path"
}

helpers_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
launch_agents_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Library/LaunchAgents"
daemon_target="$helpers_dir/harness"
plist_name="Q498EB36N4.io.harnessmonitor.daemon.plist"
plist_target="$launch_agents_dir/$plist_name"
# The bundled plist's `Label` MUST equal the plist filename without its
# `.plist` extension or `SMAppService.register()` returns
# `error: 22 (EINVAL)` on macOS 26 and silently leaves
# `Service status: 3 (.notFound)` — the daemon never registers and
# `Bootstrapping daemon client for managed daemon mode` then stalls
# forever. The lane name still flows into the daemon via the
# `HARNESS_MONITOR_RUNTIME_LANE` env entry below; we do not need it on
# the launchd label as well. The pre-coexistence label format
# `<base>.<lane>` worked by accident because the legacy plist was
# registered on a much earlier macOS where SMAppService did not yet
# enforce this match.
launch_agent_label="Q498EB36N4.io.harnessmonitor.daemon"
app_group_id="$(harness_monitor_runtime_app_group_id)"
bundle_stamp_path="${SCRIPT_OUTPUT_FILE_8:-${DERIVED_FILE_DIR:-$TARGET_BUILD_DIR}/$TARGET_NAME-bundle-daemon-agent.stamp}"

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
timestamp_flag="ad-hoc"
if [ -n "$codesign_identity" ]; then
  # Xcode-driven Release lanes provide a real timestamp via env;
  # local debug lanes opt out so codesign never blocks on the network.
  timestamp_flag="${HARNESS_DAEMON_CODESIGN_TIMESTAMP:---timestamp=none}"
fi

bundle_stamp_contents="$(
  {
    printf 'daemon_source=%s\n' "$daemon_source"
    printf 'daemon_source_stat=%s\n' "$(file_stat_signature "$daemon_source")"
    printf 'codesign_identity=%s\n' "${codesign_identity:--}"
    printf 'timestamp_flag=%s\n' "$timestamp_flag"
    printf 'launch_agent_label=%s\n' "$launch_agent_label"
    printf 'app_group_id=%s\n' "$app_group_id"
    printf 'marketing_version=%s\n' "${MARKETING_VERSION:-}"
    printf 'daemon_data_home=%s\n' "${HARNESS_DAEMON_DATA_HOME:-}"
    printf 'codex_ws_port=%s\n' "${HARNESS_CODEX_WS_PORT:-}"
    printf 'runtime_lane=%s\n' "${HARNESS_MONITOR_RUNTIME_LANE:-}"
    printf 'daemon_plist_sha=%s\n' "$(file_sha256 "$PROJECT_DIR/Resources/LaunchAgents/$plist_name")"
    printf 'legacy_managed_plist_sha=%s\n' \
      "$(file_sha256 "$PROJECT_DIR/Resources/LaunchAgents/io.harnessmonitor.daemon.managed.plist")"
    printf 'legacy_plist_sha=%s\n' \
      "$(file_sha256 "$PROJECT_DIR/Resources/LaunchAgents/io.harnessmonitor.daemon.plist")"
    printf 'entitlements_sha=%s\n' "$(file_sha256 "$PROJECT_DIR/HarnessMonitorDaemon.entitlements")"
  }
)"

# Keep the stamp comparison ahead of the expensive copy/plutil/otool/codesign
# path. The old order still spent ~15s re-signing the daemon helper on every
# no-op Xcode build before discovering nothing had changed.
if [ -f "$bundle_stamp_path" ] \
  && [ -x "$daemon_target" ] \
  && [ -f "$plist_target" ] \
  && { [ ! -f "$PROJECT_DIR/Resources/LaunchAgents/io.harnessmonitor.daemon.managed.plist" ] \
    || [ -f "$launch_agents_dir/io.harnessmonitor.daemon.managed.plist" ]; } \
  && { [ ! -f "$PROJECT_DIR/Resources/LaunchAgents/io.harnessmonitor.daemon.plist" ] \
    || [ -f "$launch_agents_dir/io.harnessmonitor.daemon.plist" ]; } \
  && [ "$(/bin/cat "$bundle_stamp_path")" = "$bundle_stamp_contents" ]; then
  exit 0
fi

/bin/mkdir -p "$helpers_dir" "$launch_agents_dir"

# Stage every mutation through `*.staging` paths in the destination
# directory and finish each bundled file with an atomic `mv`.
# In-place rewrites of `daemon_target` while a managed daemon was running
# triggered `OS_REASON_CODESIGNING` SIGKILLs on the live process whenever
# kernel page validation re-checked the now-mismatched signature, which
# produced visible WebSocket reconnect cycles each time anyone rebuilt
# the app. `mv` allocates a new inode for the destination, so the running
# process keeps mapping its original (now-unlinked) inode with the
# original signature until it exits cleanly.
#
# The staging suffix is a fixed string (not `$$`) so the paths can be
# declared in this script phase's `outputPaths` — Xcode's user-script
# sandbox (`ENABLE_USER_SCRIPT_SANDBOXING=YES` in IDE-driven builds)
# blocks any write outside the declared output set. See
# `Tuist/ProjectDescriptionHelpers/BuildPhases.swift::bundleDaemonAgent`.
daemon_target_staging="$daemon_target.staging"
plist_target_staging="$plist_target.staging"
cleanup_staging() {
  /bin/rm -f "$daemon_target_staging" "$plist_target_staging" 2>/dev/null || true
}
trap cleanup_staging EXIT

package_version="$(resolve_package_version)"
validate_package_version "$package_version" "${MARKETING_VERSION:-}"

# `cp -p` preserves the linker-signed cs_mtime alignment from
# `target/debug/harness` (rustc/lld embeds an ad-hoc CodeDirectory whose
# cs_mtime is captured at link time). Plain `cp` updates the destination
# mtime to NOW, which leaves cs_mtime in the embedded signature
# pointing at link-time — kernel page validation then rejects the
# launch with "cs_mtime != mtime" (SIGKILL CODESIGNING) before our
# resign step below has a chance to run, racing against `launchctl
# kickstart` retries while the daemon is being rebuilt.
/bin/cp -p "$daemon_source" "$daemon_target_staging"
/bin/chmod 755 "$daemon_target_staging"
/usr/bin/xattr -dr com.apple.provenance "$daemon_target_staging" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.quarantine "$daemon_target_staging" 2>/dev/null || true
/bin/cp "$PROJECT_DIR/Resources/LaunchAgents/$plist_name" "$plist_target_staging"
/usr/bin/plutil -replace Label -string "$launch_agent_label" "$plist_target_staging"
/usr/bin/plutil -replace EnvironmentVariables.HARNESS_APP_GROUP_ID -string "$app_group_id" "$plist_target_staging"
if [[ -n "${HARNESS_DAEMON_DATA_HOME:-}" ]]; then
  /usr/bin/plutil -replace EnvironmentVariables.HARNESS_DAEMON_DATA_HOME -string "$HARNESS_DAEMON_DATA_HOME" "$plist_target_staging"
fi
if [[ -n "${HARNESS_CODEX_WS_PORT:-}" ]]; then
  /usr/bin/plutil -replace EnvironmentVariables.HARNESS_CODEX_WS_PORT -string "$HARNESS_CODEX_WS_PORT" "$plist_target_staging"
fi
if [[ -n "${HARNESS_MONITOR_RUNTIME_LANE:-}" ]]; then
  /usr/bin/plutil -replace EnvironmentVariables.HARNESS_MONITOR_RUNTIME_LANE -string "$HARNESS_MONITOR_RUNTIME_LANE" "$plist_target_staging"
fi
# Always reassert the ownership env so the bundled daemon writes into the
# managed/ ownership subtree even if a stray HARNESS_DAEMON_OWNERSHIP override
# made it into the build environment.
/usr/bin/plutil -replace EnvironmentVariables.HARNESS_DAEMON_OWNERSHIP -string "managed" "$plist_target_staging"
/usr/bin/plutil -lint "$plist_target_staging"

for legacy_plist_name in \
  io.harnessmonitor.daemon.managed.plist \
  io.harnessmonitor.daemon.plist; do
  legacy_source="$PROJECT_DIR/Resources/LaunchAgents/$legacy_plist_name"
  legacy_target="$launch_agents_dir/$legacy_plist_name"
  if [ -f "$legacy_source" ]; then
    /bin/cp "$legacy_source" "$legacy_target"
    /usr/bin/plutil -lint "$legacy_target"
  fi
done

if ! /usr/bin/otool -l "$daemon_target_staging" | /usr/bin/grep -q "__info_plist"; then
  printf 'Harness daemon helper is missing embedded Info.plist metadata: %s\n' "$daemon_target_staging" >&2
  exit 1
fi

if [ -n "$codesign_identity" ]; then
  /usr/bin/codesign \
    --force \
    --sign "$codesign_identity" \
    --options runtime \
    "$timestamp_flag" \
    --identifier "$launch_agent_label" \
    --entitlements "$PROJECT_DIR/HarnessMonitorDaemon.entitlements" \
    "$daemon_target_staging"
  /usr/bin/codesign --verify --verbose=2 "$daemon_target_staging"
else
  # No usable identity (CI without keychain). Refresh the ad-hoc
  # signature so cs_mtime aligns with the post-cp file mtime, giving
  # launchd at least a chance to spawn the helper in degraded mode.
  /usr/bin/codesign \
    --force \
    --sign - \
    --identifier "$launch_agent_label" \
    "$daemon_target_staging"
fi

# Atomically replace the destination paths. `mv` on the same filesystem
# is `rename(2)` and leaves any process that has the old inode mapped
# (the running managed daemon) untouched, so the kernel keeps validating
# pages against the original signature and never raises CODESIGNING.
/bin/mv -f "$daemon_target_staging" "$daemon_target"
/bin/mv -f "$plist_target_staging" "$plist_target"

# Reseal the app bundle so SMAppService can validate the bundled launch agent
# plist. Without a `_CodeSignature/CodeResources` manifest, SMAppService refuses
# to register the plist with `errSecCSUnsigned` (-67056) on first approval, and
# `Bootstrapping daemon client for managed daemon mode` stalls because
# `launchAgentRegistrationState()` reports `.notFound`. Xcode normally writes
# this manifest as part of its bundle-signing phase, but `CODE_SIGNING_ALLOWED=NO`
# in the dev build wrapper short-circuits it; we replicate the essential part
# here so the dev flow stays usable without forcing a signing identity.
#
# Skipped when the Xcode user script sandbox is active: codesign would need to
# read every file under the .app and write `_CodeSignature/CodeResources`, none
# of which are in this phase's declared outputs, so the kernel sandbox would
# block it with `Sandbox: codesign(...) deny(1) file-read-data` against
# Contents/Info.plist and Contents/MacOS/<name>. The Xcode UI build path that
# enables this sandbox also signs the bundle itself via the standard signing
# phase, so the manifest still ends up correct there.
if [ "${ENABLE_USER_SCRIPT_SANDBOXING:-}" != "YES" ]; then
  app_bundle="$TARGET_BUILD_DIR/$WRAPPER_NAME"
  bundle_identity="$codesign_identity"
  if [ -z "$bundle_identity" ]; then
    bundle_identity="-"
  fi
  # Sign loose Mach-O subcomponents under MacOS/ first. Xcode would normally do
  # this as part of its bundle-signing phase, but `CODE_SIGNING_ALLOWED=NO` (or a
  # missing signature on a fresh target) leaves `__preview.dylib` and
  # `<exec>.debug.dylib` unsigned, which makes the parent bundle sign fail with
  # "code object is not signed at all / In subcomponent: ... __preview.dylib".
  for sub in "$app_bundle/Contents/MacOS"/*.dylib; do
    if [ -f "$sub" ]; then
      /usr/bin/codesign --force --sign "$bundle_identity" "$sub"
    fi
  done
  # Use `--entitlements` instead of `--preserve-metadata=entitlements` so the
  # step works on fresh builds where Xcode has not yet attached a signature.
  # `--preserve-metadata=entitlements` fails with "code object is not signed at
  # all" on first build of a new target (no existing CodeSignature to inherit
  # from), and that is exactly the situation for the `HarnessMonitorExternalDaemon`
  # target on a clean tree. Xcode resolves `CODE_SIGN_ENTITLEMENTS` to the
  # per-target generated entitlements that `prepare-app-entitlements.sh` writes
  # ahead of the build, so this produces the same effective entitlements set.
  bundle_codesign_args=(
    --force
    --sign "$bundle_identity"
  )
  if [ -n "${CODE_SIGN_ENTITLEMENTS:-}" ] && [ -f "$CODE_SIGN_ENTITLEMENTS" ]; then
    bundle_codesign_args+=(--entitlements "$CODE_SIGN_ENTITLEMENTS")
  fi
  /usr/bin/codesign "${bundle_codesign_args[@]}" "$app_bundle"
fi

/bin/mkdir -p "$(dirname "$bundle_stamp_path")"
printf '%s\n' "$bundle_stamp_contents" >"$bundle_stamp_path"
