#!/bin/bash

# Helpers for the wrapper-level "skip build-for-testing when fresh" gate.
# Sourced by test-swift.sh. Required env on entry:
#   ROOT                  - apps/harness-monitor-macos
#   CHECKOUT_ROOT         - the harness checkout containing apps/, scripts/, mcp-servers/
#   DERIVED_DATA_PATH     - resolved xcode-derived or xcode-derived-lanes/<lane>
#
# Defaults to ON. Break-glass: HARNESS_MONITOR_FORCE_BUILD_FOR_TESTING=1.

existing_xctestrun_path() {
  local product_dir="$DERIVED_DATA_PATH/Build/Products"
  if [[ ! -d "$product_dir" ]]; then
    return 1
  fi
  local newest=""
  local newest_epoch=0
  local candidate epoch
  shopt -s nullglob
  for candidate in "$product_dir"/*.xctestrun; do
    [[ -s "$candidate" ]] || continue
    epoch="$(/usr/bin/stat -f '%m' "$candidate" 2>/dev/null || printf '0')"
    if (( epoch >= newest_epoch )); then
      newest_epoch="$epoch"
      newest="$candidate"
    fi
  done
  shopt -u nullglob
  if [[ -z "$newest" ]]; then
    return 1
  fi
  printf '%s\n' "$newest"
}

ui_test_runner_products() {
  local selector="${XCODE_ONLY_TESTING:-}"
  local product_dir="$DERIVED_DATA_PATH/Build/Products/Debug"
  case "$selector" in
    *HarnessMonitorUITests*)
      printf '%s\n' "$product_dir/HarnessMonitorUITests-Runner.app"
      ;;
  esac
  case "$selector" in
    *HarnessMonitorAgentsE2ETests*)
      printf '%s\n' "$product_dir/HarnessMonitorAgentsE2ETests-Runner.app"
      ;;
  esac
}

ui_test_runners_are_valid() {
  local runner saw_runner=0
  while IFS= read -r runner; do
    [[ -n "$runner" ]] || continue
    saw_runner=1
    [[ -d "$runner" ]] || return 1
    /usr/bin/codesign --verify --deep --strict "$runner" >/dev/null 2>&1 || return 1
  done < <(ui_test_runner_products)

  # No UI runner expected for this selector.
  (( saw_runner == 0 )) && return 0
  return 0
}

# Skip the build-for-testing step when the existing .xctestrun is newer than
# every Swift source, project descriptor, and SPM lockfile that could affect
# the test bundle. Defaults ON because chained focused reruns rarely change
# code between calls; saved cost per skip is two xcodebuild cold starts plus
# a tuist graph parse. Freshness scope covers Sources/Tests, Tuist project
# descriptors, the SPM lockfile under .xcworkspace/xcshareddata, and the
# cross-project mcp-servers tree (HarnessMonitorRegistry framework).
should_reuse_existing_build_for_testing() {
  case "${HARNESS_MONITOR_FORCE_BUILD_FOR_TESTING:-0}" in
    1|true|TRUE|yes|YES|on|ON) return 1 ;;
  esac

  local xctestrun_path
  if ! xctestrun_path="$(existing_xctestrun_path)"; then
    return 1
  fi
  local xctestrun_epoch
  xctestrun_epoch="$(/usr/bin/stat -f '%m' "$xctestrun_path" 2>/dev/null || printf '0')"
  if (( xctestrun_epoch == 0 )); then
    return 1
  fi

  if ! ui_test_runners_are_valid; then
    return 1
  fi

  # shellcheck disable=SC2153 # ROOT/CHECKOUT_ROOT/DERIVED_DATA_PATH set by caller
  local -a freshness_roots=(
    "$ROOT/Sources"
    "$ROOT/Tests"
    "$ROOT/Project.swift"
    "$ROOT/Tuist"
    "$ROOT/HarnessMonitor.xcworkspace/xcshareddata"
    "$ROOT/HarnessMonitor.xcodeproj/project.pbxproj"
  )
  if [[ -d "$CHECKOUT_ROOT/mcp-servers" ]]; then
    freshness_roots+=("$CHECKOUT_ROOT/mcp-servers")
  fi

  local -a existing_roots=()
  local root
  for root in "${freshness_roots[@]}"; do
    [[ -e "$root" ]] && existing_roots+=("$root")
  done
  if (( ${#existing_roots[@]} == 0 )); then
    return 1
  fi

  local newer_source
  newer_source="$(
    /usr/bin/find \
      "${existing_roots[@]}" \
      \( \
        -path "$ROOT/Tuist/.build" -o \
        -path "*/.build" -o \
        -path "*/.swiftpm" -o \
        -path "*/.cache" \
      \) -prune -o \
      -newer "$xctestrun_path" -type f -print 2>/dev/null \
      | head -n 1
  )"
  if [[ -n "$newer_source" ]]; then
    return 1
  fi

  printf 'reuse-build-for-testing: skipping build (set HARNESS_MONITOR_FORCE_BUILD_FOR_TESTING=1 to override); xctestrun=%s\n' \
    "$xctestrun_path" >&2
  return 0
}
