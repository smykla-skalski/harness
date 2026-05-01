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
LEGACY_TUIST_OPT_OUT="${HARNESS_MONITOR_USE_TUIST_TEST:-}"
# Path contract:
# - every monitor lane uses `tuist xcodebuild` from the app root
# - caller-provided relative path flags keep caller-PWD semantics even though
#   Tuist changes the working directory internally
# - the approved shared DerivedData aliases (`xcode-derived*`) resolve at the
#   common repo root so linked worktrees share the same lock/cache domain
# This wrapper is the canonical xcodebuild entrypoint for repo scripts.
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/rtk-shell.sh
source "$SCRIPT_DIR/lib/rtk-shell.sh"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/non-indexable-roots.sh
source "$SCRIPT_DIR/lib/non-indexable-roots.sh"
# shellcheck source=scripts/lib/lease-lock.sh
LEASE_LOCK_DIR=""
LEASE_LOCK_RESOURCE=""

STALE_CHECK_SCRIPT="$SCRIPT_CHECKOUT_ROOT/scripts/check-no-stale-state.sh"
RUN_STARTED_AT_EPOCH="$(date +%s)"

if [[ -n "$LEGACY_TUIST_OPT_OUT" ]]; then
  printf '%s\n' \
    'HARNESS_MONITOR_USE_TUIST_TEST is no longer supported; all Harness Monitor xcodebuild lanes already use Tuist' \
    >&2
  exit 1
fi

MAX_DB_RETRIES="${XCODEBUILD_DB_RETRIES:-3}"
REGENERATE_AFTER_SUCCESS="${HARNESS_MONITOR_REGENERATE_AFTER_XCODEBUILD:-0}"
TEST_RETRY_ITERATIONS="${HARNESS_MONITOR_TEST_RETRY_ITERATIONS:-0}"
JUNIT_REPORT_DIR="${HARNESS_MONITOR_JUNIT_REPORT_DIR:-$COMMON_REPO_ROOT/tmp/scan}"
FAILURE_REPORT_DIR="${HARNESS_MONITOR_FAILURE_REPORT_DIR:-$COMMON_REPO_ROOT/tmp/scan}"
TRANSIENT_DB_STATUS=200
LEASE_LOCK_HEARTBEAT_SECONDS="${XCODEBUILD_LOCK_HEARTBEAT_SECONDS:-30}"
LEASE_LOCK_POLL_SECONDS="${XCODEBUILD_LOCK_POLL_SECONDS:-1}"
LEGACY_XCODEBUILD_LOCK_TIMEOUT_SECONDS="${XCODEBUILD_LOCK_LEASE_TIMEOUT_SECONDS:-90}"
LEASE_LOCK_OWNER_STALE_AFTER_SECONDS="${XCODEBUILD_LOCK_STALE_AFTER_SECONDS:-$LEGACY_XCODEBUILD_LOCK_TIMEOUT_SECONDS}"
# Default to fail-fast for xcodebuild lock contention so local feedback stays
# interactive. Set XCODEBUILD_LOCK_WAIT_TIMEOUT_SECONDS=0 to opt back into
# indefinite queueing behind another mutator.
LEASE_LOCK_WAITER_TIMEOUT_SECONDS="${XCODEBUILD_LOCK_WAIT_TIMEOUT_SECONDS:-15}"
LEASE_LOCK_TIMEOUT_SECONDS="$LEASE_LOCK_OWNER_STALE_AFTER_SECONDS"

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
  local index arg flag normalized_path raw_path
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
  elif [[ "${args[index]}" == -derivedDataPath=* ]]; then
    derive_data_path="${args[index]#*=}"
    has_derived_data_path=1
  fi
done
if (( has_derived_data_path == 0 )); then
  args=("-derivedDataPath" "$derive_data_path" "${args[@]}")
fi

ensure_non_indexable_directory "$derive_data_path"

lock_path="$derive_data_path/.xcodebuild.lock"
LEASE_LOCK_DIR="$lock_path"
LEASE_LOCK_RESOURCE="xcodebuild:${derive_data_path}"
LEASE_LOCK_COMMON_REPO_ROOT="$COMMON_REPO_ROOT"
source "$SCRIPT_CHECKOUT_ROOT/scripts/lib/lease-lock.sh"

current_lock_owner_pid() {
  if [[ -f "$LEASE_LOCK_OWNER_FILE" ]]; then
    sed -n 's/^LOCK_PID=//p' "$LEASE_LOCK_OWNER_FILE" | head -n 1
    return 0
  fi
  return 1
}

remove_lock_path() {
  /bin/rm -rf "$lock_path"
}

cleanup_lock() {
  lease_lock_cleanup
}

cleanup_descendants_and_lock() {
  local status="${1:-$?}"
  trap - EXIT INT TERM HUP
  terminate_descendant_processes "$$"
  cleanup_lock
  exit "$status"
}

harness_monitor_record_xcodebuild_capture_pid() {
  local capture_pid="$1"
  local mutator_pid
  mutator_pid="$(xcodebuild_mutator_pid "$capture_pid")"
  lease_lock_record_mutator_process "$mutator_pid"
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

create_failure_report_base() {
  local timestamp
  timestamp="$(date +%Y%m%d-%H%M%S)"
  /bin/mkdir -p "$FAILURE_REPORT_DIR"
  printf '%s/xcodebuild-failure-%s-%s\n' "$FAILURE_REPORT_DIR" "$timestamp" "$$"
}

persist_failure_report() {
  local status="$1"
  local log_path="$2"
  local raw_log_path="$3"
  local report_base report_path console_copy raw_copy

  report_base="$(create_failure_report_base)"
  report_path="${report_base}.report.txt"
  console_copy="${report_base}.console.log"
  raw_copy="${report_base}.raw.log"

  /bin/cp "$log_path" "$console_copy"
  /bin/cp "$raw_log_path" "$raw_copy"

  {
    printf 'Harness Monitor xcodebuild failure report\n'
    printf 'status: %s\n' "$status"
    printf 'app_root: %s\n' "$ROOT"
    printf 'caller_pwd: %s\n' "$CALLER_PWD"
    printf 'derived_data_path: %s\n' "$derive_data_path"
    printf 'console_log: %s\n' "$console_copy"
    printf 'raw_log: %s\n' "$raw_copy"
    printf '\n'
    printf 'normalized_args:'
    local arg
    for arg in "${args[@]}"; do
      printf ' %q' "$arg"
    done
    printf '\n\n'
    printf '===== filtered-console-output =====\n'
    /bin/cat "$console_copy"
    printf '\n===== raw-xcodebuild-output =====\n'
    /bin/cat "$raw_copy"
  } > "$report_path"

  printf '%s\n' "$report_path"
}

emit_failure_report_footer() {
  local report_path="$1"
  local console_copy="$2"
  local raw_copy="$3"
  printf '%s\n' \
    "xcodebuild-wrapper failure error fail full-report path=${report_path} console_log=${console_copy} raw_log=${raw_copy}" \
    >&2
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

emit_swift_dia_diagnostics() {
  local min_epoch="${1:-0}"
  local diagnostics_root diagnostics_file emitted files_file line output shown
  diagnostics_root="$derive_data_path/Build/Intermediates.noindex"
  if [[ ! -d "$diagnostics_root" ]]; then
    return 0
  fi

  files_file="$(mktemp "${TMPDIR:-/tmp}/harness-xcodebuild-dia.XXXXXX")"
  /usr/bin/find "$diagnostics_root" -type f -name '*.dia' -size +0c \
    -exec /usr/bin/stat -f '%m %N' {} + 2>/dev/null \
    | /usr/bin/awk -v min_epoch="$min_epoch" '$1 >= min_epoch { print }' \
    | /usr/bin/sort -n \
    | /usr/bin/tail -80 \
    | /usr/bin/sed 's/^[0-9][0-9]* //' > "$files_file"

  emitted=0
  while IFS= read -r diagnostics_file; do
    if [[ -z "$diagnostics_file" || ! -f "$diagnostics_file" ]]; then
      continue
    fi
    output="$(
      strings "$diagnostics_file" \
        | /usr/bin/awk '
          /^DIAG$/ || /^C8< $/ { next }

          /^\/.*\.swift$/ {
            print
            detail_count = 0
            next
          }

          detail_count < 3 && NF > 0 {
            print
            detail_count += 1
          }
        ' \
        | /usr/bin/head -40 || true
    )"
    if [[ -z "$output" ]]; then
      continue
    fi
    if (( emitted == 0 )); then
      printf 'swift-diagnostics: extracted compiler diagnostics from .dia files\n' >&2
    fi
    emitted=$((emitted + 1))
    printf 'swift-diagnostics: %s\n' "$diagnostics_file" >&2
    shown=0
    while IFS= read -r line; do
      if [[ -n "$line" ]]; then
        printf 'swift-diagnostics:   %s\n' "$line" >&2
        shown=$((shown + 1))
      fi
      if (( shown >= 12 )); then
        break
      fi
    done <<< "$output"
    if (( emitted >= 8 )); then
      break
    fi
  done < "$files_file"
  /bin/rm -f "$files_file"
}

raw_log_has_compiler_diagnostics() {
  local raw_log_path="$1"
  [[ -f "$raw_log_path" ]] || return 1
  /usr/bin/grep -Eq '^/.*:[0-9]+:[0-9]+:\s+(error|warning|note):' "$raw_log_path"
}

emit_raw_compiler_diagnostics() {
  local raw_log_path="$1"
  [[ -f "$raw_log_path" ]] || return 1

  /usr/bin/awk '
    BEGIN {
      emitted = 0
      capture = 0
      max_blocks = 12
    }

    function flush_line(prefix, value) {
      if (value != "") {
        printf "%s%s\n", prefix, value > "/dev/stderr"
      }
    }

    match($0, /^\/.*:[0-9]+:[0-9]+: (error|warning|note):/) {
      if (seen[$0]++) {
        capture = 0
        next
      }
      if (emitted == 0) {
        flush_line("swift-raw-diagnostics: ", "extracted compiler diagnostics from raw xcodebuild output")
      }
      emitted += 1
      flush_line("swift-raw-diagnostics: ", $0)
      capture = 2
      if (emitted >= max_blocks) {
        exit
      }
      next
    }

    capture > 0 {
      flush_line("swift-raw-diagnostics:   ", $0)
      capture -= 1
    }
  ' "$raw_log_path"
}

lock_owner_command() {
  local owner_pid="$1"
  /bin/ps -p "$owner_pid" -o command= 2>/dev/null | /usr/bin/sed 's/^[[:space:]]*//'
}

acquire_lock() {
  /bin/mkdir -p "$derive_data_path"
  lease_lock_acquire
}

build_test_action_args() {
  local -a out=("${args[@]}")
  if (( TEST_RETRY_ITERATIONS > 0 )) \
      && ! xcodebuild_args_target_ui_tests "${args[@]}" \
      && ! xcodebuild_args_have_flag "-retry-tests-on-failure" "${args[@]}" \
      && ! xcodebuild_args_have_flag "-test-iterations" "${args[@]}"; then
    out+=("-retry-tests-on-failure" "-test-iterations" "$TEST_RETRY_ITERATIONS")
  fi
  printf '%s\n' "${out[@]}"
}

xcodebuild_args_target_ui_tests() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      *HarnessMonitorUITests*)
        return 0
        ;;
    esac
  done
  return 1
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

emit_path_arg_vector() {
  local label="$1"
  shift
  local -a path_args=()
  local -a source_args=("$@")
  local index arg flag
  for ((index = 0; index < ${#source_args[@]}; index += 1)); do
    arg="${source_args[index]}"
    if xcodebuild_flag_requires_path_value "$arg" \
        && (( index + 1 < ${#source_args[@]} )); then
      path_args+=("$arg" "${source_args[index + 1]}")
      index=$((index + 1))
      continue
    fi
    if [[ "$arg" == *=* ]]; then
      flag="${arg%%=*}"
      if xcodebuild_flag_requires_path_value "$flag"; then
        path_args+=("$arg")
      fi
    fi
  done
  if (( ${#path_args[@]} == 0 )); then
    return 0
  fi
  emit_arg_vector "$label" "${path_args[@]}"
}

filter_xcodebuild_console_output() {
  /usr/bin/awk '
    /^note: Local cache/ { next }
    /^note: L/ { next }
    /^note: Replay cache/ { next }
    /^note: Re/ { next }
    /^note: R/ { next }
    /^note: Using CAS/ { next }
    /^note: Us/ { next }
    /^note: U$/ { next }
    /^note: Lo$/ { next }
    /^note: Building targets in dependency order/ { next }
    /^note: Target dependency graph / { next }
    /^note: Using stub executor library / { next }
    /^note: [0-9]+ hits \/ [0-9]+ cacheable tasks / { next }
    /^Using cache binaries for the following targets:/ { next }
    /^Loading and constructing the graph$/ { next }
    /^It might take a while if the cache is empty$/ { next }
    /^Generating workspace / { next }
    /^Generating project / { next }
    /^Total time taken: / { next }
    /^✔ Success $/ { next }
    /^  Project generated\. $/ { next }
    { print }
  '
}

emit_wrapper_failure_context() {
  local mapping
  emit_path_arg_vector "xcodebuild-wrapper: original path args:" "${original_args[@]}"
  emit_path_arg_vector "xcodebuild-wrapper: normalized path args:" "${args[@]}"
  if (( ${#normalized_path_mappings[@]} == 0 )); then
    return 0
  fi
  for mapping in "${normalized_path_mappings[@]}"; do
    printf 'path-normalization: %s\n' "$mapping" >&2
  done
}

run_inner() {
  local log_path="$1"
  local raw_log_path="$2"
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
  XCODEBUILD_RAW_LOG_PATH="$raw_log_path" \
    run_xcodebuild_with_formatter ${fmt_prefix[@]+"${fmt_prefix[@]}"} "${inner_args[@]}" \
    >"$log_path" 2>&1
  local status="$?"
  set -e
  filter_xcodebuild_console_output <"$log_path"
  return "$status"
}

run_once() {
  local log_path raw_log_path status report_path report_base console_copy raw_copy
  log_path="$(create_temp_log_path)"
  raw_log_path="$(create_temp_log_path)"
  set +e
  run_inner "$log_path" "$raw_log_path"
  status=$?
  set -e

  if (( status == 0 )); then
    normalize_shared_schemes_after_xcodebuild
    /bin/rm -f "$log_path"
    /bin/rm -f "$raw_log_path"
    return 0
  fi

  if is_db_transient_failure "$log_path" || latest_activity_log_has_transient_db_failure; then
    printf 'Detected transient xcodebuild database failure in build logs\n' >&2
    /bin/rm -f "$log_path"
    /bin/rm -f "$raw_log_path"
    return "$TRANSIENT_DB_STATUS"
  fi

  emit_wrapper_failure_context

  if (( status != 127 )) && log_needs_swift_compile_context "$log_path"; then
    if raw_log_has_compiler_diagnostics "$raw_log_path"; then
      emit_raw_compiler_diagnostics "$raw_log_path"
    else
      emit_swift_compile_context
      emit_swift_dia_diagnostics "$RUN_STARTED_AT_EPOCH"
    fi
  fi

  report_path="$(persist_failure_report "$status" "$log_path" "$raw_log_path")"
  report_base="${report_path%.report.txt}"
  console_copy="${report_base}.console.log"
  raw_copy="${report_base}.raw.log"
  emit_failure_report_footer "$report_path" "$console_copy" "$raw_copy"

  /bin/rm -f "$log_path"
  /bin/rm -f "$raw_log_path"
  return "$status"
}

run_stale_preflight() {
  if [[ "${HARNESS_SKIP_STALE_CHECK:-0}" == "1" ]]; then
    return 0
  fi

  if [[ ! -x "$STALE_CHECK_SCRIPT" ]]; then
    printf 'stale-check script is not executable: %s\n' "$STALE_CHECK_SCRIPT" >&2
    exit 1
  fi

  "$STALE_CHECK_SCRIPT"
}

trap 'cleanup_descendants_and_lock $?' EXIT
trap 'cleanup_descendants_and_lock 130' INT
trap 'cleanup_descendants_and_lock 143' TERM
trap 'cleanup_descendants_and_lock 129' HUP
run_stale_preflight
acquire_lock

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
