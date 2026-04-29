#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
CHECKOUT_ROOT="$(CDPATH='' cd -- "$ROOT/../.." && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$CHECKOUT_ROOT/scripts/lib/common-repo-root.sh"
COMMON_REPO_ROOT="$(resolve_common_repo_root "$CHECKOUT_ROOT")"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/xcodebuild-destination.sh
source "$ROOT/Scripts/lib/xcodebuild-destination.sh"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/rtk-shell.sh
source "$ROOT/Scripts/lib/rtk-shell.sh"
DESTINATION="$(harness_monitor_xcodebuild_destination)"
DERIVED_DATA_PATH="${XCODEBUILD_DERIVED_DATA_PATH:-$COMMON_REPO_ROOT/xcode-derived}"
CANONICAL_XCODEBUILD_RUNNER="$ROOT/Scripts/xcodebuild-with-lock.sh"
XCODEBUILD_RUNNER="${XCODEBUILD_RUNNER:-$CANONICAL_XCODEBUILD_RUNNER}"
GENERATE_PROJECT_SCRIPT="${GENERATE_PROJECT_SCRIPT:-$ROOT/Scripts/generate.sh}"

cleanup_script_descendants() {
  local status="${1:-$?}"
  trap - EXIT INT TERM HUP
  terminate_descendant_processes "$$"
  exit "$status"
}

run_background_and_wait() {
  local child_pid status
  set +e
  "$@" &
  child_pid=$!
  wait "$child_pid"
  status=$?
  set -e
  return "$status"
}

# Unit and app-test builds exercise Swift code and do not need the embedded
# Rust daemon helper. Keep the default macOS test lane out of Cargo and the
# shared daemon target directory; build/quality lanes can opt back in. Pass the
# values both as environment and Xcode build settings so scheme pre-actions and
# target script phases see the same contract.
DAEMON_AGENT_BUILD_SKIP="${HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUILD:-1}"
DAEMON_AGENT_BUNDLE_SKIP="${HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE:-1}"
export HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUILD="$DAEMON_AGENT_BUILD_SKIP"
export HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE="$DAEMON_AGENT_BUNDLE_SKIP"

if [ "${XCODEBUILD_RUNNER}" != "${CANONICAL_XCODEBUILD_RUNNER}" ]; then
  echo "XCODEBUILD_RUNNER override is unsupported; use ${CANONICAL_XCODEBUILD_RUNNER}" >&2
  exit 1
fi

if [ ! -x "${XCODEBUILD_RUNNER}" ]; then
  echo "xcodebuild runner is not executable: ${XCODEBUILD_RUNNER}" >&2
  exit 1
fi

if [ ! -x "${GENERATE_PROJECT_SCRIPT}" ]; then
  echo "generate script is not executable: ${GENERATE_PROJECT_SCRIPT}" >&2
  exit 1
fi

trap 'cleanup_script_descendants $?' EXIT
trap 'cleanup_script_descendants 130' INT
trap 'cleanup_script_descendants 143' TERM
trap 'cleanup_script_descendants 129' HUP

run_background_and_wait "$GENERATE_PROJECT_SCRIPT"

exec "$XCODEBUILD_RUNNER" \
  -workspace "$ROOT/HarnessMonitor.xcworkspace" \
  -scheme "HarnessMonitor" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUILD="$DAEMON_AGENT_BUILD_SKIP" \
  HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE="$DAEMON_AGENT_BUNDLE_SKIP" \
  build-for-testing
