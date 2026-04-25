#!/usr/bin/env bash

e2e_repo_root() {
  local script_dir
  script_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  CDPATH='' cd -- "$script_dir/../.." && pwd
}

portable_timeout() {
  local seconds="$1"
  shift
  if [[ "$seconds" == "" || "$#" -eq 0 ]]; then
    printf 'portable_timeout requires seconds and command\n' >&2
    return 64
  fi

  "$@" &
  local command_pid=$!
  (
    sleep "$seconds"
    kill -TERM "$command_pid" 2>/dev/null || true
  ) &
  local timer_pid=$!

  local status=0
  wait "$command_pid" || status=$?
  kill "$timer_pid" 2>/dev/null || true
  wait "$timer_pid" 2>/dev/null || true
  return "$status"
}

e2e_require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'error: required command not found: %s\n' "$command_name" >&2
    return 1
  fi
}

e2e_random_id() {
  if ! command -v uuidgen >/dev/null 2>&1; then
    printf 'error: uuidgen is required for e2e_random_id\n' >&2
    return 1
  fi
  uuidgen | tr '[:upper:]' '[:lower:]'
}

e2e_resolve_harness_binary() {
  local root="$1"
  local cargo_target_dir
  cargo_target_dir="$(
    "$root/scripts/cargo-local.sh" --print-env \
      | awk -F= '/^CARGO_TARGET_DIR=/{print $2}'
  )"
  if [[ -z "$cargo_target_dir" ]]; then
    printf 'error: failed to resolve CARGO_TARGET_DIR\n' >&2
    return 1
  fi
  printf '%s/debug/harness\n' "$cargo_target_dir"
}

e2e_project_context_root() {
  local project_dir="$1"
  local data_home="$2"
  local canonical
  canonical="$(CDPATH='' cd -- "$project_dir" && pwd -P)"
  local digest
  digest="$(printf '%s' "$canonical" | shasum -a 256 | awk '{print substr($1,1,16)}')"
  printf '%s/harness/projects/project-%s\n' "$data_home" "$digest"
}

e2e_write_kv_marker() {
  local path="$1"
  shift
  mkdir -p "$(dirname -- "$path")"
  : >"$path"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >>"$path"
  done
}

e2e_wait_for_file() {
  local path="$1"
  local timeout_seconds="${2:-90}"
  local deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    if [[ -f "$path" ]]; then
      return 0
    fi
    sleep 0.2
  done
  printf 'error: timed out waiting for %s\n' "$path" >&2
  return 1
}

e2e_timestamp_utc() {
  TZ=UTC date '+%Y-%m-%dT%H:%M:%SZ'
}

e2e_timestamp_slug_utc() {
  TZ=UTC date '+%y%m%d%H%M%S'
}

e2e_run_with_log() {
  local log_path="$1"
  shift

  mkdir -p "$(dirname -- "$log_path")"
  set +e
  "$@" 2>&1 | tee "$log_path"
  local statuses=("${PIPESTATUS[@]}")
  set -e

  local command_status="${statuses[0]:-0}"
  local tee_status="${statuses[1]:-0}"
  if [[ "$command_status" -ne 0 ]]; then
    return "$command_status"
  fi
  return "$tee_status"
}
