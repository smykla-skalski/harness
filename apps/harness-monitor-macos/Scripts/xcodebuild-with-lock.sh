#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
ROOT="${HARNESS_MONITOR_APP_ROOT:-$ROOT}"
REPO_ROOT="$(CDPATH='' cd -- "$ROOT/../.." && pwd)"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/rtk-shell.sh
source "$SCRIPT_DIR/lib/rtk-shell.sh"

DEFAULT_DERIVED_DATA_PATH="${XCODEBUILD_DERIVED_DATA_PATH:-$REPO_ROOT/xcode-derived}"
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
  log_path="$(mktemp "${TMPDIR:-/tmp}/harness-xcodebuild.XXXXXX.log")"
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

  /bin/rm -f "$log_path"
  return "$status"
}

acquire_lock
trap cleanup_lock EXIT

attempt=1
while true; do
  if run_once; then
    exit 0
  fi

  status="$?"
  if (( status != TRANSIENT_DB_STATUS )) || (( attempt >= MAX_DB_RETRIES )); then
    exit "$status"
  fi

  printf 'Detected transient build database failure, resetting XCBuildData and retrying (%s/%s)\n' \
    "$attempt" "$MAX_DB_RETRIES" >&2
  recover_build_db
  attempt=$((attempt + 1))
done
