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
  local expanded_selector expanded_selectors selector
  while IFS= read -r selector; do
    if [[ -n "$selector" ]]; then
      if ! expanded_selectors="$(expand_only_testing_selector "$selector")"; then
        return 1
      fi
      while IFS= read -r expanded_selector; do
        if [[ -n "$expanded_selector" ]]; then
          TEST_ARGS+=("-only-testing:${expanded_selector}")
        fi
      done <<< "$expanded_selectors"
    fi
  done < <(printf '%s\n' "$XCODE_ONLY_TESTING" | tr ',' '\n')
}

expand_only_testing_selector() {
  local selector="$1"

  if [[ "$selector" != */* ]] || [[ "$selector" == */*/* ]]; then
    printf '%s\n' "$selector"
    return 0
  fi

  enumerate_only_testing_selector "$selector"
}

enumerate_only_testing_selector() {
  local selector="$1"
  local enumeration_dir enumeration_log_path enumeration_path expanded_selectors

  if [ ! -x /usr/bin/python3 ]; then
    echo "python3 is required to expand XCODE_ONLY_TESTING class selector: ${selector}" >&2
    return 1
  fi

  enumeration_dir="$(mktemp -d "${TMPDIR:-/tmp}/harness-monitor-tests.XXXXXX")"
  enumeration_path="$enumeration_dir/tests.json"
  enumeration_log_path="$enumeration_dir/xcodebuild.log"
  if ! HARNESS_MONITOR_TEST_RETRY_ITERATIONS=0 \
      "$XCODEBUILD_RUNNER" \
    "${BASE_TEST_ARGS[@]}" \
    "-only-testing:${selector}" \
    -enumerate-tests \
    -test-enumeration-style flat \
    -test-enumeration-format json \
    -test-enumeration-output-path "$enumeration_path" >"$enumeration_log_path" 2>&1; then
    /usr/bin/tail -n 80 "$enumeration_log_path" >&2 || true
    /bin/rm -rf "$enumeration_dir"
    echo "failed to enumerate tests for XCODE_ONLY_TESTING selector: ${selector}" >&2
    return 1
  fi

  if ! expanded_selectors="$(/usr/bin/python3 - "$enumeration_path" "$selector" <<'PY'
import json
import sys

path = sys.argv[1]
selector = sys.argv[2]

with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)

identifiers = {}
for value in payload.get("values", []):
    for test in value.get("enabledTests", []):
        identifier = test.get("identifier", "")
        if identifier.startswith(selector + "/"):
            identifiers[identifier] = None

for identifier in identifiers:
    print(identifier)
PY
  )"; then
    /bin/rm -rf "$enumeration_dir"
    echo "failed to parse enumerated tests for XCODE_ONLY_TESTING selector: ${selector}" >&2
    return 1
  fi
  /bin/rm -rf "$enumeration_dir"

  if [[ -z "$expanded_selectors" ]]; then
    echo "no tests discovered for XCODE_ONLY_TESTING class selector: ${selector}" >&2
    return 1
  fi

  printf '%s\n' "$expanded_selectors"
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

if [ ! -x "${BUILD_FOR_TESTING_SCRIPT}" ]; then
  echo "build-for-testing script is not executable: ${BUILD_FOR_TESTING_SCRIPT}" >&2
  exit 1
fi

"$BUILD_FOR_TESTING_SCRIPT"

clear_gatekeeper_metadata

BASE_TEST_ARGS=(
  -workspace "$ROOT/HarnessMonitor.xcworkspace" \
  -scheme "HarnessMonitor" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building
)
TEST_ARGS=("${BASE_TEST_ARGS[@]}")

append_only_testing_args
append_default_skip_args

if [[ -n "$XCODE_ONLY_TESTING" ]] && [[ "${#TEST_ARGS[@]}" == "${#BASE_TEST_ARGS[@]}" ]]; then
  echo "no tests discovered for XCODE_ONLY_TESTING selector(s): ${XCODE_ONLY_TESTING}" >&2
  exit 1
fi

"$XCODEBUILD_RUNNER" \
  "${TEST_ARGS[@]}"
