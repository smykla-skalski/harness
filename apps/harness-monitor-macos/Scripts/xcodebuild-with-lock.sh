#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
SCRIPT_CHECKOUT_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd)"
ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
ROOT="${HARNESS_MONITOR_APP_ROOT:-$ROOT}"
CHECKOUT_ROOT="$(CDPATH='' cd -- "$ROOT/../.." && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$SCRIPT_CHECKOUT_ROOT/scripts/lib/common-repo-root.sh"
COMMON_REPO_ROOT="$(resolve_common_repo_root "$CHECKOUT_ROOT")"
CALLER_PWD="$(pwd -P)"
# Path contract:
# - every monitor lane uses `tuist xcodebuild` from the app root
# - caller-provided relative path flags keep caller-PWD semantics even though
#   Tuist changes the working directory internally
# - the approved shared DerivedData aliases (`xcode-derived*`) resolve at the
#   common repo root so linked worktrees share the same lock/cache domain
# This wrapper is the canonical xcodebuild entrypoint for repo scripts.
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/rtk-shell.sh
source "$SCRIPT_DIR/lib/rtk-shell.sh"

LOCK_TIMEOUT_SECONDS="${XCODEBUILD_LOCK_TIMEOUT_SECONDS:-900}"
LOCK_POLL_SECONDS="${XCODEBUILD_LOCK_POLL_SECONDS:-1}"
MAX_DB_RETRIES="${XCODEBUILD_DB_RETRIES:-3}"
REGENERATE_AFTER_SUCCESS="${HARNESS_MONITOR_REGENERATE_AFTER_XCODEBUILD:-0}"
TEST_RETRY_ITERATIONS="${HARNESS_MONITOR_TEST_RETRY_ITERATIONS:-2}"
JUNIT_REPORT_DIR="${HARNESS_MONITOR_JUNIT_REPORT_DIR:-$COMMON_REPO_ROOT/tmp/scan}"
TRANSIENT_DB_STATUS=200

export HARNESS_MONITOR_APP_ROOT="$ROOT"

original_args=("$@")
args=("$@")
normalized_path_mappings=()

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
  local index arg normalized_path
  for ((index = 0; index < ${#args[@]}; index += 1)); do
    arg="${args[index]}"
    if xcodebuild_flag_requires_path_value "$arg" \
        && (( index + 1 < ${#args[@]} )); then
      normalized_path="$(normalize_path_flag_value "$arg" "${args[index + 1]}")"
      record_normalized_path_mapping "$arg" "${args[index + 1]}" "$normalized_path"
      normalized_args+=("$arg" "$normalized_path")
      index=$((index + 1))
      continue
    fi
    normalized_args+=("$arg")
  done
  args=("${normalized_args[@]}")
}

normalize_default_derived_data_path() {
  local raw_path normalized_path
  raw_path="${XCODEBUILD_DERIVED_DATA_PATH:-$COMMON_REPO_ROOT/xcode-derived}"
  normalized_path="$(resolve_derived_data_path_arg "$raw_path")"
  record_normalized_path_mapping "-derivedDataPath" "$raw_path" "$normalized_path"
  printf '%s\n' "$normalized_path"
}

normalize_xcodebuild_path_args

DEFAULT_DERIVED_DATA_PATH="$(normalize_default_derived_data_path)"
derive_data_path="$DEFAULT_DERIVED_DATA_PATH"
has_derived_data_path=0
for ((index = 0; index < ${#args[@]}; index += 1)); do
  if [[ "${args[index]}" == "-derivedDataPath" ]] && (( index + 1 < ${#args[@]} )); then
    derive_data_path="${args[index + 1]}"
    has_derived_data_path=1
  fi
done
if (( has_derived_data_path == 0 )); then
  args=("-derivedDataPath" "$derive_data_path" "${args[@]}")
fi

lock_dir="$derive_data_path/.xcodebuild.lock"
lock_pid_file="$lock_dir/pid"

cleanup_lock() {
  if [[ -d "$lock_dir" ]] && [[ -f "$lock_pid_file" ]]; then
    local owner_pid
    owner_pid="$(cat "$lock_pid_file" 2>/dev/null || true)"
    if [[ "$owner_pid" == "$$" ]]; then
      /bin/rm -rf "$lock_dir"
    fi
  fi
}

is_db_transient_failure() {
  local log_path="$1"
  /usr/bin/grep -Eq 'database is locked|accessing build database ".*build\.db": disk I/O error' "$log_path"
}

latest_activity_log_has_transient_db_failure() {
  local activity_log
  activity_log="$(latest_nonempty_activity_log || true)"
  if [[ -z "$activity_log" ]]; then
    return 1
  fi

  /usr/bin/gzip -dc "$activity_log" 2>/dev/null \
    | strings \
    | /usr/bin/grep -Eq \
      'database is locked|accessing build database ".*build\.db": disk I/O error'
}

recover_build_db() {
  local xcbuild_data_path="$derive_data_path/Build/Intermediates.noindex/XCBuildData"
  if [[ -d "$xcbuild_data_path" ]]; then
    /bin/rm -rf "$xcbuild_data_path"
  fi
}

normalize_shared_schemes_after_xcodebuild() {
  case "$REGENERATE_AFTER_SUCCESS" in
    1|true|TRUE|yes|YES|on|ON) ;;
    *) return 0 ;;
  esac

  # Tuist owns scheme XML; callers can opt in to regenerating it after
  # xcodebuild mutates xcshareddata. Quiet because schemes are not tracked.
  HARNESS_MONITOR_APP_ROOT="$ROOT" \
    "$ROOT/Scripts/generate.sh" >/dev/null
}

create_temp_log_path() {
  local temp_root log_stem log_path
  temp_root="${TMPDIR:-/tmp}"
  log_stem="$(mktemp "${temp_root%/}/harness-xcodebuild.XXXXXX")"
  log_path="${log_stem}.log"
  /bin/mv "$log_stem" "$log_path"
  printf '%s\n' "$log_path"
}

latest_nonempty_activity_log() {
  local logs_root latest_entry
  logs_root="$derive_data_path/Logs/Build"
  if [[ ! -d "$logs_root" ]]; then
    return 1
  fi

  latest_entry="$(
    /usr/bin/find "$logs_root" -type f -name '*.xcactivitylog' -size +0c \
      -exec /usr/bin/stat -f '%m %N' {} + 2>/dev/null \
      | /usr/bin/sort -n \
      | /usr/bin/tail -1
  )"
  if [[ -z "$latest_entry" ]]; then
    return 1
  fi

  printf '%s\n' "${latest_entry#* }"
}

latest_swift_file_list_from_activity_log() {
  local activity_log compile_line swift_file_list
  activity_log="$1"
  compile_line="$(
    /usr/bin/gzip -dc "$activity_log" 2>/dev/null \
      | strings \
      | /usr/bin/grep 'builtin-Swift-Compilation -- ' \
      | /usr/bin/tail -1 || true
  )"
  if [[ -z "$compile_line" ]]; then
    return 1
  fi

  swift_file_list="$(
    printf '%s\n' "$compile_line" \
      | /usr/bin/sed -n 's/.* @\([^[:space:]]*SwiftFileList\).*/\1/p'
  )"
  if [[ -z "$swift_file_list" ]]; then
    return 1
  fi

  printf '%s\n' "${swift_file_list//\\ / }"
}

log_needs_swift_compile_context() {
  local log_path="$1"
  if /usr/bin/grep -Eq '^/.*:[0-9]+:[0-9]+:\s+(error|warning|note):' "$log_path"; then
    return 1
  fi
  if /usr/bin/grep -Eq "^Test (Suite|Case) '|^Executed [0-9]+ tests?" "$log_path"; then
    return 1
  fi
  if /usr/bin/grep -Eq '^ld:\s+|^Undefined symbols|^Code Sign error:' "$log_path"; then
    return 1
  fi
  return 0
}

emit_swift_compile_context() {
  local activity_log swift_file_list total_sources shown_sources source_path
  activity_log="$(latest_nonempty_activity_log || true)"
  if [[ -z "$activity_log" ]]; then
    return 0
  fi

  printf 'swift-compile-context: latest non-empty activity log: %s\n' "$activity_log" >&2

  swift_file_list="$(latest_swift_file_list_from_activity_log "$activity_log" || true)"
  if [[ -z "$swift_file_list" ]]; then
    printf 'swift-compile-context: no Swift compilation batch found in that activity log\n' >&2
    return 0
  fi

  printf 'swift-compile-context: latest Swift batch file list: %s\n' "$swift_file_list" >&2
  if [[ ! -f "$swift_file_list" ]]; then
    printf 'swift-compile-context: Swift file list path missing on disk\n' >&2
    return 0
  fi

  total_sources="$(/usr/bin/wc -l < "$swift_file_list" | tr -d ' ')"
  printf 'swift-compile-context: candidate source files (%s total, showing up to 8)\n' "$total_sources" >&2

  shown_sources=0
  while IFS= read -r source_path; do
    if [[ -z "$source_path" ]]; then
      continue
    fi
    printf 'swift-compile-context: source: %s\n' "$source_path" >&2
    shown_sources=$((shown_sources + 1))
    if (( shown_sources >= 8 )); then
      break
    fi
  done < "$swift_file_list"

  if (( total_sources > shown_sources )); then
    printf 'swift-compile-context: additional source files omitted: %s\n' \
      "$((total_sources - shown_sources))" >&2
  fi
}

lock_owner_command() {
  local owner_pid="$1"
  /bin/ps -p "$owner_pid" -o command= 2>/dev/null | /usr/bin/sed 's/^[[:space:]]*//'
}

acquire_lock() {
  local started_at now owner_pid owner_command last_reported_owner
  /bin/mkdir -p "$derive_data_path"
  started_at="$(date +%s)"
  last_reported_owner=""
  while ! /bin/mkdir "$lock_dir" 2>/dev/null; do
    owner_pid=""
    if [[ -f "$lock_pid_file" ]]; then
      owner_pid="$(cat "$lock_pid_file" 2>/dev/null || true)"
      if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
        /bin/rm -rf "$lock_dir"
        continue
      fi
    fi

    if [[ "$owner_pid" != "$last_reported_owner" ]]; then
      printf 'Waiting for xcodebuild lock at %s\n' "$lock_dir" >&2
      if [[ -n "$owner_pid" ]]; then
        printf 'lock owner pid: %s\n' "$owner_pid" >&2
        owner_command="$(lock_owner_command "$owner_pid" || true)"
        if [[ -n "$owner_command" ]]; then
          printf 'lock owner command: %s\n' "$owner_command" >&2
        fi
      fi
      last_reported_owner="$owner_pid"
    fi

    now="$(date +%s)"
    if (( now - started_at >= LOCK_TIMEOUT_SECONDS )); then
      printf 'Timed out waiting for xcodebuild lock at %s\n' "$lock_dir" >&2
      exit 1
    fi
    sleep "$LOCK_POLL_SECONDS"
  done
  printf '%s\n' "$$" > "$lock_pid_file"
}

build_test_action_args() {
  local -a out=("${args[@]}")
  if (( TEST_RETRY_ITERATIONS > 0 )) \
      && ! xcodebuild_args_have_flag "-retry-tests-on-failure" "${args[@]}" \
      && ! xcodebuild_args_have_flag "-test-iterations" "${args[@]}"; then
    out+=("-retry-tests-on-failure" "-test-iterations" "$TEST_RETRY_ITERATIONS")
  fi
  printf '%s\n' "${out[@]}"
}

junit_report_path_for_run() {
  /bin/mkdir -p "$JUNIT_REPORT_DIR"
  printf '%s/junit-%s-%s.xml\n' "$JUNIT_REPORT_DIR" "$$" "$(date +%s)"
}

emit_arg_vector() {
  local label="$1"
  shift
  local arg
  printf '%s' "$label" >&2
  for arg in "$@"; do
    printf ' %q' "$arg" >&2
  done
  printf '\n' >&2
}

emit_wrapper_failure_context() {
  local mapping
  emit_arg_vector "xcodebuild-wrapper: original args:" "${original_args[@]}"
  emit_arg_vector "xcodebuild-wrapper: normalized args:" "${args[@]}"
  if (( ${#normalized_path_mappings[@]} == 0 )); then
    return 0
  fi
  for mapping in "${normalized_path_mappings[@]}"; do
    printf 'path-normalization: %s\n' "$mapping" >&2
  done
}

run_inner() {
  local log_path="$1"
  local -a inner_args=("${args[@]}")
  local -a fmt_prefix=(--use-tuist)
  local line
  if xcodebuild_args_are_test_action "${args[@]}"; then
    inner_args=()
    while IFS= read -r line; do
      inner_args+=("$line")
    done < <(build_test_action_args)
    fmt_prefix+=(--junit-path "$(junit_report_path_for_run)")
  fi
  set +e
  run_xcodebuild_with_formatter ${fmt_prefix[@]+"${fmt_prefix[@]}"} "${inner_args[@]}" 2>&1 | tee "$log_path"
  local status="${PIPESTATUS[0]}"
  set -e
  return "$status"
}

run_once() {
  local log_path status
  log_path="$(create_temp_log_path)"
  run_inner "$log_path"
  status=$?

  if (( status == 0 )); then
    normalize_shared_schemes_after_xcodebuild
    /bin/rm -f "$log_path"
    return 0
  fi

  if is_db_transient_failure "$log_path" || latest_activity_log_has_transient_db_failure; then
    printf 'Detected transient xcodebuild database failure in build logs\n' >&2
    /bin/rm -f "$log_path"
    return "$TRANSIENT_DB_STATUS"
  fi

  emit_wrapper_failure_context

  if (( status != 127 )) && log_needs_swift_compile_context "$log_path"; then
    emit_swift_compile_context
  fi

  /bin/rm -f "$log_path"
  return "$status"
}

acquire_lock
trap cleanup_lock EXIT

attempt=1
while true; do
  if run_once; then
    exit 0
  else
    status="$?"
  fi
  if (( status != TRANSIENT_DB_STATUS )) || (( attempt >= MAX_DB_RETRIES )); then
    exit "$status"
  fi

  printf 'Detected transient build database failure, resetting XCBuildData and retrying (%s/%s)\n' \
    "$attempt" "$MAX_DB_RETRIES" >&2
  recover_build_db
  attempt=$((attempt + 1))
done
