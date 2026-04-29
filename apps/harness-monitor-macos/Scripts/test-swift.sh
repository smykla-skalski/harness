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
STALE_CHECK_SCRIPT="$CHECKOUT_ROOT/scripts/check-no-stale-state.sh"
DESTINATION="$(harness_monitor_xcodebuild_destination)"
DERIVED_DATA_PATH="${XCODEBUILD_DERIVED_DATA_PATH:-$COMMON_REPO_ROOT/xcode-derived}"
CANONICAL_XCODEBUILD_RUNNER="$ROOT/Scripts/xcodebuild-with-lock.sh"
XCODEBUILD_RUNNER="${XCODEBUILD_RUNNER:-$CANONICAL_XCODEBUILD_RUNNER}"
XCODE_ONLY_TESTING="${XCODE_ONLY_TESTING:-}"
BUILD_FOR_TESTING_SCRIPT="${BUILD_FOR_TESTING_SCRIPT:-$ROOT/Scripts/build-for-testing.sh}"

cleanup_script_descendants() {
  local status="${1:-$?}"
  trap - EXIT INT TERM HUP
  terminate_descendant_processes "$$"
  exit "$status"
}

run_stale_preflight() {
  if [[ "${HARNESS_SKIP_STALE_CHECK:-0}" == "1" ]]; then
    return 0
  fi

  if [[ ! -x "$STALE_CHECK_SCRIPT" ]]; then
    echo "stale-check script is not executable: $STALE_CHECK_SCRIPT" >&2
    exit 1
  fi

  local -a stale_env=()
  if [[ -n "$XCODE_ONLY_TESTING" ]]; then
    # Focused excerpts should not be blocked by unrelated long-lived daemon locks.
    # Keep all other stale-state checks active.
    stale_env+=(HARNESS_CHECK_ALLOW_DAEMON_LOCK_HOLDERS=1)
  fi

  if (( ${#stale_env[@]} > 0 )); then
    env "${stale_env[@]}" "$STALE_CHECK_SCRIPT"
  else
    "$STALE_CHECK_SCRIPT"
  fi
}

run_test_action() {
  if [[ -n "$XCODE_ONLY_TESTING" ]]; then
    exec env \
      HARNESS_SKIP_STALE_CHECK=1 \
      HARNESS_MONITOR_DISABLE_XCBEAUTIFY=1 \
      "$XCODEBUILD_RUNNER" "${TEST_ARGS[@]}"
  else
    exec env HARNESS_SKIP_STALE_CHECK=1 "$XCODEBUILD_RUNNER" "${TEST_ARGS[@]}"
  fi
}

run_only_testing_enumeration() {
  local selector="$1"
  local enumeration_path="$2"
  HARNESS_MONITOR_TEST_RETRY_ITERATIONS=0 \
    HARNESS_SKIP_STALE_CHECK=1 \
    "$XCODEBUILD_RUNNER" \
    "${BASE_TEST_ARGS[@]}" \
    "-only-testing:${selector}" \
    -enumerate-tests \
    -test-enumeration-style flat \
    -test-enumeration-format json \
    -test-enumeration-output-path "$enumeration_path"
}

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

filter_monitor_test_console_output() {
  /usr/bin/awk '
    /^Using cache binaries for the following targets:/ { next }
    /^Loading and constructing the graph$/ { next }
    /^It might take a while if the cache is empty$/ { next }
    /^Generating workspace / { next }
    /^Generating project / { next }
    /^Total time taken: / { next }
    /^✔ Success $/ { next }
    /^  Project generated\. $/ { next }
    /^note: Local cache/ { next }
    /^note: L/ { next }
    /^note: Replay cache/ { next }
    /^note: Re/ { next }
    /^note: R/ { next }
    /^note: Using CAS/ { next }
    /^note: Us/ { next }
    /^note: U$/ { next }
    /^note: Lo$/ { next }
    { print }
  '
}

run_build_for_testing() {
  local build_log_path
  build_log_path="$(mktemp "${TMPDIR:-/tmp}/harness-monitor-build-for-testing.XXXXXX.log")"
  set +e
  HARNESS_SKIP_STALE_CHECK=1 "$BUILD_FOR_TESTING_SCRIPT" >"$build_log_path" 2>&1
  local status="$?"
  set -e
  filter_monitor_test_console_output <"$build_log_path"
  /bin/rm -f "$build_log_path"
  return "$status"
}

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

  if [[ "$selector" != */* ]]; then
    printf '%s\n' "$selector"
    return 0
  fi

  # Fully-qualified selectors already point to one test method.
  # Avoid enumerate-tests here because xcodebuild enumeration can stall.
  if [[ "$selector" == */*/* ]]; then
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
  if ! run_only_testing_enumeration \
    "$selector" \
    "$enumeration_path" >"$enumeration_log_path" 2>&1; then
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

def canonical(value):
    if value.startswith("test://"):
        # Xcode copies links as test://com.apple.xcode/<app>/<target>/<suite>/<test>.
        # The -only-testing flag wants <target>/<suite>/<test>.
        parts = value.split("/")
        if len(parts) >= 6:
            value = "/".join(parts[4:])
    value = value.strip("/")
    if value.endswith("()"):
        value = value[:-2]
    return value


def selector_matches(identifier, selector):
    canonical_identifier = canonical(identifier)
    canonical_selector = canonical(selector)
    return (
        canonical_identifier == canonical_selector
        or canonical_identifier.startswith(canonical_selector + "/")
    )


identifiers = {}
all_tests = []
for value in payload.get("values", []):
    enabled_tests = value.get("enabledTests", [])
    all_tests.extend(enabled_tests)
    all_tests.extend(value.get("disabledTests", []))
    for test in enabled_tests:
        identifier = test.get("identifier", "")
        if selector_matches(identifier, selector):
            identifiers[identifier] = None

if not identifiers:
    for test in all_tests:
        identifier = test.get("identifier", "")
        if selector_matches(identifier, selector):
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
    if [[ "$selector" == */*/* ]]; then
      printf '%s\n' "$selector"
      return 0
    fi
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

run_stale_preflight

trap 'cleanup_script_descendants $?' EXIT
trap 'cleanup_script_descendants 130' INT
trap 'cleanup_script_descendants 143' TERM
trap 'cleanup_script_descendants 129' HUP

run_build_for_testing

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

run_test_action
