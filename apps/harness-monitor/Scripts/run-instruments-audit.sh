#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
APP_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
CHECKOUT_ROOT="$(CDPATH='' cd -- "$APP_ROOT/../.." && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$CHECKOUT_ROOT/scripts/lib/common-repo-root.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/xcodebuild-destination.sh
source "$SCRIPT_DIR/lib/xcodebuild-destination.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/swift-tool-env.sh
source "$SCRIPT_DIR/lib/swift-tool-env.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/swift-package-freshness.sh
source "$SCRIPT_DIR/lib/swift-package-freshness.sh"
sanitize_xcode_only_swift_environment

CANONICAL_XCODEBUILD_RUNNER="$APP_ROOT/Scripts/monitor-xcodebuild.sh"
XCODEBUILD_RUNNER="${XCODEBUILD_RUNNER:-$CANONICAL_XCODEBUILD_RUNNER}"
PERF_CLI_PACKAGE_DIR="$APP_ROOT/Tools/HarnessMonitorPerf"
PERF_CLI_BINARY="$(
  ensure_swift_package_release_binary_fresh \
    "$PERF_CLI_PACKAGE_DIR" \
    "harness-monitor-perf"
)"

COMMON_REPO_ROOT="$(resolve_common_repo_root "$CHECKOUT_ROOT")"
DESTINATION="$(harness_monitor_xcodebuild_destination)"
DERIVED_DATA_PATH="$COMMON_REPO_ROOT/xcode-derived-instruments"
RUNS_ROOT="$COMMON_REPO_ROOT/tmp/perf/harness-monitor-instruments/runs"
STAGED_HOST_ROOT="$COMMON_REPO_ROOT/tmp/perf/harness-monitor-instruments/staged-host"
DAEMON_CARGO_TARGET_DIR="$(
  "$CHECKOUT_ROOT/scripts/cargo-local.sh" --print-env \
    | awk -F= '/^CARGO_TARGET_DIR=/{print $2}'
)"
ARCH="${HARNESS_MONITOR_AUDIT_BUILD_ARCH:-$(uname -m)}"

audit_args=(
  --checkout-root "$CHECKOUT_ROOT"
  --common-repo-root "$COMMON_REPO_ROOT"
  --app-root "$APP_ROOT"
  --xcodebuild-runner "$XCODEBUILD_RUNNER"
  --destination "$DESTINATION"
  --derived-data-path "$DERIVED_DATA_PATH"
  --runs-root "$RUNS_ROOT"
  --staged-host-root "$STAGED_HOST_ROOT"
  --daemon-cargo-target-dir "$DAEMON_CARGO_TARGET_DIR"
  --arch "$ARCH"
)

"$PERF_CLI_BINARY" audit "${audit_args[@]}" "$@"
