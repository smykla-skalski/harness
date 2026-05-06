#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="${HARNESS_MONITOR_APP_ROOT:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)}"
CHECKOUT_ROOT="$(CDPATH='' cd -- "$ROOT/../.." && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$CHECKOUT_ROOT/scripts/lib/common-repo-root.sh"
COMMON_REPO_ROOT="$(resolve_common_repo_root "$CHECKOUT_ROOT")"
CALLER_PWD="$(pwd -P)"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/monitor-lanes.sh
source "$SCRIPT_DIR/lib/monitor-lanes.sh"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/non-indexable-roots.sh
source "$SCRIPT_DIR/lib/non-indexable-roots.sh"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/rtk-shell.sh
source "$SCRIPT_DIR/lib/rtk-shell.sh"

STALE_CHECK_SCRIPT="$CHECKOUT_ROOT/scripts/check-no-stale-state.sh"
FAILURE_REPORT_DIR="${HARNESS_MONITOR_FAILURE_REPORT_DIR:-$COMMON_REPO_ROOT/tmp/scan}"
LOCK_WAIT_TIMEOUT_SECONDS="${XCODEBUILD_LOCK_WAIT_TIMEOUT_SECONDS:-15}"

export HARNESS_MONITOR_APP_ROOT="$ROOT"

args=("$@")
normalized_path_mappings=()
derive_data_path=""
lock_path=""
lock_owned=0

record_normalized_path_mapping() {
  local flag="$1"
  local raw_path="$2"
  local normalized_path="$3"
  if [[ "$raw_path" != "$normalized_path" ]]; then
    normalized_path_mappings+=("$flag $raw_path -> $normalized_path")
  fi
}

resolve_invocation_relative_path() {
  local raw_path="$1"
  if [[ "$raw_path" == /* ]]; then
    printf '%s\n' "$raw_path"
    return 0
  fi
  printf '%s/%s\n' "${CALLER_PWD%/}" "$raw_path"
}

resolve_derived_data_path_arg() {
  local raw_path="$1"
  if [[ "$raw_path" == /* ]]; then
    printf '%s\n' "$raw_path"
    return 0
  fi
  case "$raw_path" in
    xcode-derived|xcode-derived-e2e|xcode-derived-instruments)
      printf '%s/%s\n' "$COMMON_REPO_ROOT" "$raw_path"
      ;;
    *)
      resolve_invocation_relative_path "$raw_path"
      ;;
  esac
}

xcodebuild_flag_requires_path_value() {
  case "$1" in
    -archivePath|-clonedSourcePackagesDirPath|-derivedDataPath|-exportPath|\
    -packageCachePath|-project|-resultBundlePath|-resultStreamPath|\
    -test-enumeration-output-path|-testProductsPath|-workspace|-xctestrun)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_path_flag_value() {
  local flag="$1"
  local raw_path="$2"
  case "$flag" in
    -derivedDataPath) resolve_derived_data_path_arg "$raw_path" ;;
    *) resolve_invocation_relative_path "$raw_path" ;;
  esac
}

normalize_xcodebuild_path_args() {
  local -a normalized_args=()
  local index arg flag raw_path normalized_path
  for ((index = 0; index < ${#args[@]}; index += 1)); do
    arg="${args[index]}"
    if xcodebuild_flag_requires_path_value "$arg" \
        && (( index + 1 < ${#args[@]} )); then
      raw_path="${args[index + 1]}"
      normalized_path="$(normalize_path_flag_value "$arg" "$raw_path")"
      record_normalized_path_mapping "$arg" "$raw_path" "$normalized_path"
      normalized_args+=("$arg" "$normalized_path")
      index=$((index + 1))
      continue
    fi
    if [[ "$arg" == *=* ]]; then
      flag="${arg%%=*}"
      if xcodebuild_flag_requires_path_value "$flag"; then
        raw_path="${arg#*=}"
        normalized_path="$(normalize_path_flag_value "$flag" "$raw_path")"
        record_normalized_path_mapping "$flag" "$raw_path" "$normalized_path"
        normalized_args+=("${flag}=${normalized_path}")
        continue
      fi
    fi
    normalized_args+=("$arg")
  done
  args=("${normalized_args[@]}")
}

find_or_inject_derived_data_path() {
  local index default_path
  default_path="$(harness_monitor_build_derived_data_path "$COMMON_REPO_ROOT")"
  derive_data_path="$default_path"
  for ((index = 0; index < ${#args[@]}; index += 1)); do
    if [[ "${args[index]}" == "-derivedDataPath" ]] && (( index + 1 < ${#args[@]} )); then
      derive_data_path="${args[index + 1]}"
      return 0
    fi
    if [[ "${args[index]}" == -derivedDataPath=* ]]; then
      derive_data_path="${args[index]#*=}"
      return 0
    fi
  done
  args=("-derivedDataPath" "$derive_data_path" "${args[@]}")
}

lock_owner_file() {
  printf '%s/owner.env\n' "$lock_path"
}

lock_owner_alive() {
  local owner_file="$1"
  local pid command
  [[ -f "$owner_file" ]] || return 1
  pid="$(sed -n 's/^pid=//p' "$owner_file" | head -n 1)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  command="$(ps -p "$pid" -o command= 2>/dev/null | sed 's/^[[:space:]]*//')"
  [[ -n "$command" ]] || return 1
  return 0
}

describe_lock_owner() {
  local owner_file="$1"
  local pid command started
  pid="$(sed -n 's/^pid=//p' "$owner_file" | head -n 1)"
  started="$(sed -n 's/^started_at=//p' "$owner_file" | head -n 1)"
  command="$(ps -p "$pid" -o command= 2>/dev/null | sed 's/^[[:space:]]*//')"
  printf 'pid=%s started_at=%s command=%s\n' "${pid:-?}" "${started:-?}" "${command:-?}"
}

acquire_xcodebuild_lock() {
  local owner_file deadline
  mkdir -p "$derive_data_path"
  lock_path="$derive_data_path/.harness-monitor-xcodebuild.lock"
  owner_file="$(lock_owner_file)"
  deadline=$((SECONDS + LOCK_WAIT_TIMEOUT_SECONDS))
  while :; do
    if mkdir "$lock_path" 2>/dev/null; then
      {
        printf 'pid=%s\n' "$$"
        printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'derived_data_path=%s\n' "$derive_data_path"
      } > "$owner_file"
      lock_owned=1
      return 0
    fi
    if ! lock_owner_alive "$owner_file"; then
      rm -rf "$lock_path"
      continue
    fi
    if (( LOCK_WAIT_TIMEOUT_SECONDS == 0 || SECONDS < deadline )); then
      sleep 1
      continue
    fi
    printf 'error: Harness Monitor xcodebuild lane is busy: %s\n' "$derive_data_path" >&2
    printf 'owner: %s\n' "$(describe_lock_owner "$owner_file")" >&2
    printf 'set XCODEBUILD_LOCK_WAIT_TIMEOUT_SECONDS=0 to wait indefinitely, or use HARNESS_MONITOR_BUILD_LANE=<name> for another lane.\n' >&2
    return 73
  done
}

release_xcodebuild_lock() {
  if (( lock_owned == 1 )) && [[ -n "$lock_path" ]]; then
    rm -rf "$lock_path"
  fi
}

cleanup_descendants_and_lock() {
  local status="${1:-$?}"
  trap - EXIT INT TERM HUP
  terminate_descendant_processes "$$"
  release_xcodebuild_lock
  exit "$status"
}

run_stale_preflight() {
  if [[ "${HARNESS_SKIP_STALE_CHECK:-0}" == "1" ]]; then
    return 0
  fi
  if [[ ! -x "$STALE_CHECK_SCRIPT" ]]; then
    printf 'stale-check script is not executable: %s\n' "$STALE_CHECK_SCRIPT" >&2
    return 1
  fi
  "$STALE_CHECK_SCRIPT"
}

create_failure_report_base() {
  mkdir -p "$FAILURE_REPORT_DIR"
  printf '%s/xcodebuild-failure-%s-%s\n' "$FAILURE_REPORT_DIR" "$(date +%Y%m%d-%H%M%S)" "$$"
}

persist_failure_report() {
  local status="$1"
  local log_path="$2"
  local report_base report_path console_copy
  report_base="$(create_failure_report_base)"
  report_path="${report_base}.report.txt"
  console_copy="${report_base}.console.log"
  cp "$log_path" "$console_copy"
  {
    printf 'Harness Monitor xcodebuild failure report\n'
    printf 'status: %s\n' "$status"
    printf 'app_root: %s\n' "$ROOT"
    printf 'caller_pwd: %s\n' "$CALLER_PWD"
    printf 'derived_data_path: %s\n' "$derive_data_path"
    printf 'console_log: %s\n' "$console_copy"
    printf '\n'
    printf 'normalized_args:'
    local arg
    for arg in "${args[@]}"; do
      printf ' %q' "$arg"
    done
    printf '\n\n'
    if (( ${#normalized_path_mappings[@]} > 0 )); then
      printf 'path_mappings:\n'
      printf '  %s\n' "${normalized_path_mappings[@]}"
      printf '\n'
    fi
    cat "$console_copy"
  } > "$report_path"
  printf '%s\n' "$report_path"
}

build_test_action_args() {
  local -a out=("${args[@]}")
  if (( ${HARNESS_MONITOR_TEST_RETRY_ITERATIONS:-0} > 0 )) \
      && xcodebuild_args_are_test_action "${args[@]}" \
      && ! xcodebuild_args_have_flag "-retry-tests-on-failure" "${args[@]}" \
      && ! xcodebuild_args_have_flag "-test-iterations" "${args[@]}"; then
    out+=("-retry-tests-on-failure" "-test-iterations" "$HARNESS_MONITOR_TEST_RETRY_ITERATIONS")
  fi
  printf '%s\n' "${out[@]}"
}

run_xcodebuild() {
  local status report_path log_path
  local -a run_args=()
  while IFS= read -r arg; do
    run_args+=("$arg")
  done < <(build_test_action_args)
  log_path="$(mktemp "${TMPDIR:-/tmp}/harness-monitor-xcodebuild.XXXXXX.log")"
  if XCODEBUILD_RAW_LOG_PATH="$log_path" \
      run_xcodebuild_with_formatter --use-tuist "${run_args[@]}"; then
    status=0
  else
    status="$?"
  fi
  if (( status != 0 )); then
    report_path="$(persist_failure_report "$status" "$log_path")"
    printf 'xcodebuild-wrapper failure report: %s\n' "$report_path" >&2
  fi
  rm -f "$log_path"
  return "$status"
}

normalize_xcodebuild_path_args
find_or_inject_derived_data_path
export XCODEBUILD_DERIVED_DATA_PATH="$derive_data_path"
ensure_non_indexable_directory "$derive_data_path"

run_stale_preflight
trap 'cleanup_descendants_and_lock $?' EXIT
trap 'cleanup_descendants_and_lock 130' INT
trap 'cleanup_descendants_and_lock 143' TERM
trap 'cleanup_descendants_and_lock 129' HUP

acquire_xcodebuild_lock
run_xcodebuild
