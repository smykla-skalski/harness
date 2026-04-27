#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
CHECKOUT_ROOT="$(CDPATH='' cd -- "$ROOT/../.." && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$CHECKOUT_ROOT/scripts/lib/common-repo-root.sh"
COMMON_REPO_ROOT="$(resolve_common_repo_root "$CHECKOUT_ROOT")"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/xcodebuild-destination.sh
source "$ROOT/Scripts/lib/xcodebuild-destination.sh"
DESTINATION="$(harness_monitor_xcodebuild_destination)"
DERIVED_DATA_PATH="${XCODEBUILD_DERIVED_DATA_PATH:-$COMMON_REPO_ROOT/xcode-derived}"
CANONICAL_XCODEBUILD_RUNNER="$ROOT/Scripts/xcodebuild-with-lock.sh"
XCODEBUILD_RUNNER="${XCODEBUILD_RUNNER:-$CANONICAL_XCODEBUILD_RUNNER}"
XCODE_ONLY_TESTING="${XCODE_ONLY_TESTING:-}"
RUN_LINT_SCRIPT="${RUN_LINT_SCRIPT:-$ROOT/Scripts/run-lint.sh}"
BUILD_FOR_TESTING_SCRIPT="${BUILD_FOR_TESTING_SCRIPT:-$ROOT/Scripts/build-for-testing.sh}"

# Targets that launch a hosted app under xctest. macOS attributes their
# startup-time app-data access to the Xcode-bundled xctest agent, which
# triggers a session-scoped "Xcode would like to access data from other
# apps" TCC prompt every time the test runner relaunches. Default-skip
# them in the fast lane so unattended runs do not block on a system
# dialog. CLAUDE.md already requires explicit user approval for UI
# suites; the explicit XCODE_ONLY_TESTING selector still opts back in.
DEFAULT_SKIP_TEST_TARGETS=(
  "HarnessMonitorUITests"
  "HarnessMonitorAgentsE2ETests"
)

append_only_testing_args() {
  local selector
  while IFS= read -r selector; do
    if [[ -n "$selector" ]]; then
      TEST_ARGS+=("-only-testing:${selector}")
    fi
  done < <(printf '%s\n' "$XCODE_ONLY_TESTING" | tr ',' '\n')
}

append_default_skip_args() {
  if [[ -n "$XCODE_ONLY_TESTING" ]]; then
    return 0
  fi

  local target
  for target in "${DEFAULT_SKIP_TEST_TARGETS[@]}"; do
    TEST_ARGS+=("-skip-testing:${target}")
  done
}

clear_gatekeeper_metadata() {
  local build_products_path path

  build_products_path="$DERIVED_DATA_PATH/Build/Products/Debug"
  if [ ! -d "$build_products_path" ]; then
    return 0
  fi

  for path in \
    "$build_products_path"/*.app \
    "$build_products_path"/*.xctest \
    "$build_products_path"/*.framework
  do
    if [ -e "$path" ]; then
      xattr -dr com.apple.provenance "$path" 2>/dev/null || true
      xattr -dr com.apple.quarantine "$path" 2>/dev/null || true
    fi
  done
}

if [ "${XCODEBUILD_RUNNER}" != "${CANONICAL_XCODEBUILD_RUNNER}" ]; then
  echo "XCODEBUILD_RUNNER override is unsupported; use ${CANONICAL_XCODEBUILD_RUNNER}" >&2
  exit 1
fi

if [ ! -x "${RUN_LINT_SCRIPT}" ]; then
  echo "lint script is not executable: ${RUN_LINT_SCRIPT}" >&2
  exit 1
fi

if [ ! -x "${BUILD_FOR_TESTING_SCRIPT}" ]; then
  echo "build-for-testing script is not executable: ${BUILD_FOR_TESTING_SCRIPT}" >&2
  exit 1
fi

"$RUN_LINT_SCRIPT"
"$BUILD_FOR_TESTING_SCRIPT"

clear_gatekeeper_metadata

TEST_ARGS=(
  -workspace "$ROOT/HarnessMonitor.xcworkspace" \
  -scheme "HarnessMonitor" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building
)

append_only_testing_args
append_default_skip_args

"$XCODEBUILD_RUNNER" \
  "${TEST_ARGS[@]}"
