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
# This wrapper is the canonical xcodebuild entrypoint for repo scripts.
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/rtk-shell.sh
source "$SCRIPT_DIR/lib/rtk-shell.sh"

DEFAULT_DERIVED_DATA_PATH="${XCODEBUILD_DERIVED_DATA_PATH:-$COMMON_REPO_ROOT/xcode-derived}"
LOCK_TIMEOUT_SECONDS="${XCODEBUILD_LOCK_TIMEOUT_SECONDS:-900}"
LOCK_POLL_SECONDS="${XCODEBUILD_LOCK_POLL_SECONDS:-1}"
MAX_DB_RETRIES="${XCODEBUILD_DB_RETRIES:-3}"
TRANSIENT_DB_STATUS=200

derive_data_path="$DEFAULT_DERIVED_DATA_PATH"
args=("$@")
for ((index = 0; index < ${#args[@]}; index += 1)); do
  if [[ "${args[index]}" == "-derivedDataPath" ]] && (( index + 1 < ${#args[@]} )); then
    derive_data_path="${args[index + 1]}"
  fi
done

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

recover_build_db() {
  local xcbuild_data_path="$derive_data_path/Build/Intermediates.noindex/XCBuildData"
  if [[ -d "$xcbuild_data_path" ]]; then
    /bin/rm -rf "$xcbuild_data_path"
  fi
}

normalize_shared_schemes_after_xcodebuild() {
  HARNESS_MONITOR_APP_ROOT="$ROOT" \
  HARNESS_MONITOR_NORMALIZE_ONLY=1 \
  HARNESS_MONITOR_SKIP_VERSION_SYNC=1 \
    "$ROOT/Scripts/generate-project.sh" >/dev/null
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

acquire_lock() {
  local started_at now owner_pid
  /bin/mkdir -p "$derive_data_path"
  started_at="$(date +%s)"
  while ! /bin/mkdir "$lock_dir" 2>/dev/null; do
    if [[ -f "$lock_pid_file" ]]; then
      owner_pid="$(cat "$lock_pid_file" 2>/dev/null || true)"
      if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
        /bin/rm -rf "$lock_dir"
        continue
      fi
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

run_once() {
  local log_path status
  log_path="$(create_temp_log_path)"
  set +e
  run_xcodebuild_command "${args[@]}" 2>&1 | tee "$log_path"
  status="${PIPESTATUS[0]}"
  set -e

  if (( status == 0 )); then
    normalize_shared_schemes_after_xcodebuild
    /bin/rm -f "$log_path"
    return 0
  fi

  if is_db_transient_failure "$log_path"; then
    /bin/rm -f "$log_path"
    return "$TRANSIENT_DB_STATUS"
  fi

  if log_needs_swift_compile_context "$log_path"; then
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
