#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/lib/process-state.sh
source "$LIB_DIR/process-state.sh"

if (( $# != 11 )); then
  printf 'usage: %s <target-pid> <heartbeat-seconds> <heartbeat-file> <metadata-file> <owner-id> <role> <state> <resource> <process-pid> <acquired-at-epoch> <repo-root>\n' "$0" >&2
  exit 1
fi

target_pid="$1"
heartbeat_seconds="$2"
heartbeat_file="$3"
metadata_file="$4"
owner_id="$5"
role="$6"
state="$7"
resource="$8"
process_pid="$9"
acquired_at_epoch="${10}"
repo_root="${11}"

command_string="$(process_state_command_string "$process_pid" || true)"
process_start="$(process_state_start_string "$process_pid" || true)"
hostname="$(process_state_hostname)"
agent_id="${HARNESS_AGENT_ID:-${CODEX_SESSION_ID:-${CLAUDE_SESSION_ID:-pid:${process_pid}@${hostname}}}}"
owner_stale_after_seconds="${LEASE_LOCK_OWNER_STALE_AFTER_SECONDS:-${LEASE_LOCK_TIMEOUT_SECONDS:-90}}"
waiter_timeout_seconds="${LEASE_LOCK_WAITER_TIMEOUT_SECONDS:-$owner_stale_after_seconds}"
sleep_pid=""

atomic_write_file() {
  local target_path="$1"
  local target_dir
  local temp_path
  target_dir="$(dirname "$target_path")"
  [[ -d "$target_dir" && -e "$metadata_file" ]] || return 1
  temp_path="${target_path}.tmp.$$"
  if ! cat >"$temp_path" 2>/dev/null; then
    rm -f "$temp_path" 2>/dev/null || true
    return 1
  fi
  if [[ ! -d "$target_dir" || ! -e "$metadata_file" ]]; then
    rm -f "$temp_path" 2>/dev/null || true
    return 1
  fi
  if ! mv -f "$temp_path" "$target_path" 2>/dev/null; then
    rm -f "$temp_path" 2>/dev/null || true
    return 1
  fi
}

cleanup() {
  if [[ -n "$sleep_pid" ]]; then
    kill "$sleep_pid" 2>/dev/null || true
    wait "$sleep_pid" 2>/dev/null || true
  fi
  exit 0
}

trap cleanup TERM INT HUP

while kill -0 "$target_pid" 2>/dev/null; do
  sleep "$heartbeat_seconds" &
  sleep_pid="$!"
  wait "$sleep_pid" 2>/dev/null || true
  sleep_pid=""
  [[ -e "$metadata_file" ]] || exit 0

  now_epoch="$(date +%s)"
  next_due_epoch="$((now_epoch + heartbeat_seconds))"
  if ! atomic_write_file "$heartbeat_file" <<EOF
$now_epoch
EOF
  then
    exit 0
  fi
  if ! atomic_write_file "$metadata_file" <<EOF
LOCK_PROTOCOL_VERSION=1
LOCK_RESOURCE=${resource}
LOCK_ROLE=${role}
LOCK_OWNER_ID=${owner_id}
LOCK_AGENT_ID=${agent_id}
LOCK_PID=${process_pid}
LOCK_HOSTNAME=${hostname}
LOCK_REPO_ROOT=${repo_root}
LOCK_COMMAND=${command_string}
LOCK_PROCESS_START=${process_start}
LOCK_ACQUIRED_AT_EPOCH=${acquired_at_epoch}
LOCK_HEARTBEAT_EVERY_SEC=${heartbeat_seconds}
LOCK_OWNER_STALE_AFTER_SEC=${owner_stale_after_seconds}
LOCK_WAITER_TIMEOUT_SEC=${waiter_timeout_seconds}
LOCK_LEASE_TIMEOUT_SEC=${owner_stale_after_seconds}
LOCK_LAST_HEARTBEAT_EPOCH=${now_epoch}
LOCK_NEXT_HEARTBEAT_DUE_EPOCH=${next_due_epoch}
LOCK_STATE=${state}
EOF
  then
    exit 0
  fi
done
