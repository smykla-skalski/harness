#!/usr/bin/env bash
# Shared lease/heartbeat lock helper for multi-agent local coordination.
# Consumers must set:
#   LEASE_LOCK_DIR       absolute path to the lock root
#   LEASE_LOCK_RESOURCE  human-readable resource name

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'error: lease-lock.sh must be sourced, not executed directly\n' >&2
  exit 1
fi

if [[ -z "${LEASE_LOCK_DIR:-}" ]]; then
  printf 'error: LEASE_LOCK_DIR must be set before sourcing lease-lock.sh\n' >&2
  return 1
fi

if [[ -z "${LEASE_LOCK_RESOURCE:-}" ]]; then
  printf 'error: LEASE_LOCK_RESOURCE must be set before sourcing lease-lock.sh\n' >&2
  return 1
fi

LEASE_LOCK_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/process-state.sh
source "$LEASE_LOCK_LIB_DIR/process-state.sh"
LEASE_LOCK_HEARTBEAT_SECONDS="${LEASE_LOCK_HEARTBEAT_SECONDS:-30}"
LEASE_LOCK_TIMEOUT_SECONDS="${LEASE_LOCK_TIMEOUT_SECONDS:-90}"
LEASE_LOCK_POLL_SECONDS="${LEASE_LOCK_POLL_SECONDS:-1}"
LEASE_LOCK_OWNER_STALE_AFTER_SECONDS="${LEASE_LOCK_OWNER_STALE_AFTER_SECONDS:-$LEASE_LOCK_TIMEOUT_SECONDS}"
LEASE_LOCK_WAITER_TIMEOUT_SECONDS="${LEASE_LOCK_WAITER_TIMEOUT_SECONDS:-$((LEASE_LOCK_OWNER_STALE_AFTER_SECONDS + LEASE_LOCK_POLL_SECONDS + 1))}"
LEASE_LOCK_OWNER_DIR="$LEASE_LOCK_DIR/owner"
LEASE_LOCK_OWNER_FILE="$LEASE_LOCK_OWNER_DIR/lease.env"
LEASE_LOCK_OWNER_HEARTBEAT_FILE="$LEASE_LOCK_OWNER_DIR/heartbeat"
LEASE_LOCK_OWNER_RUNTIME_FILE="$LEASE_LOCK_OWNER_DIR/runtime.env"
LEASE_LOCK_WAITERS_DIR="$LEASE_LOCK_DIR/waiters"
LEASE_LOCK_WAITER_ID="${LEASE_LOCK_WAITER_ID:-$$}"
LEASE_LOCK_HEARTBEAT_HELPER="$LEASE_LOCK_LIB_DIR/lease-lock-heartbeat.sh"
LEASE_LOCK_OWNER_ID=""
LEASE_LOCK_WAITER_FILE="$LEASE_LOCK_WAITERS_DIR/${LEASE_LOCK_WAITER_ID}.env"
LEASE_LOCK_HEARTBEAT_PID=""
LEASE_LOCK_WAITER_HEARTBEAT_PID=""
LEASE_LOCK_LAST_STARTED_HEARTBEAT_PID=""
LEASE_LOCK_OWNS_LOCK=0
LEASE_LOCK_REGISTERED_WAITER=0

lease_lock_hostname() {
  process_state_hostname
}

lease_lock_agent_id() {
  if [[ -n "${HARNESS_AGENT_ID:-}" ]]; then
    printf '%s\n' "$HARNESS_AGENT_ID"
    return 0
  fi
  if [[ -n "${CODEX_SESSION_ID:-}" ]]; then
    printf 'codex:%s\n' "$CODEX_SESSION_ID"
    return 0
  fi
  if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
    printf 'claude:%s\n' "$CLAUDE_SESSION_ID"
    return 0
  fi
  printf 'pid:%s@%s\n' "$$" "$(lease_lock_hostname)"
}

lease_lock_command_string() {
  local target_pid="${1:-$$}"
  local command_string
  command_string="$(process_state_command_string "$target_pid" || true)"
  if [[ -n "$command_string" ]]; then
    printf '%s\n' "$command_string"
    return 0
  fi
  printf '%s\n' "${0##*/}"
}

lease_lock_process_start_string() {
  local target_pid="${1:-$$}"
  process_state_start_string "$target_pid"
}

lease_lock_now_epoch() {
  date +%s
}

lease_lock_next_due_epoch() {
  local now_epoch="$1"
  printf '%s\n' "$((now_epoch + LEASE_LOCK_HEARTBEAT_SECONDS))"
}

lease_lock_is_expired_epoch() {
  local last_heartbeat_epoch="$1"
  local now_epoch="$2"
  (( now_epoch - last_heartbeat_epoch > LEASE_LOCK_OWNER_STALE_AFTER_SECONDS ))
}

lease_lock_atomic_write_file() {
  local target_path="$1"
  local target_dir
  local temp_path
  target_dir="$(/usr/bin/dirname "$target_path")"
  [[ -d "$target_dir" ]] || return 1
  temp_path="${target_path}.tmp.$$"
  if ! /bin/cat >"$temp_path" 2>/dev/null; then
    /bin/rm -f "$temp_path" 2>/dev/null || true
    return 1
  fi
  if [[ ! -d "$target_dir" ]]; then
    /bin/rm -f "$temp_path" 2>/dev/null || true
    return 1
  fi
  if ! /bin/mv -f "$temp_path" "$target_path" 2>/dev/null; then
    /bin/rm -f "$temp_path" 2>/dev/null || true
    return 1
  fi
}

lease_lock_write_metadata_file() {
  local target_path="$1"
  local owner_id="$2"
  local role="$3"
  local last_heartbeat_epoch="$4"
  local next_due_epoch="$5"
  local state="$6"
  local process_pid process_start

  process_pid="${LEASE_LOCK_PROCESS_PID:-$$}"
  process_start="$(lease_lock_process_start_string "$process_pid" || true)"

  lease_lock_atomic_write_file "$target_path" <<EOF
LOCK_PROTOCOL_VERSION=1
LOCK_RESOURCE=${LEASE_LOCK_RESOURCE}
LOCK_ROLE=${role}
LOCK_OWNER_ID=${owner_id}
LOCK_AGENT_ID=$(lease_lock_agent_id)
LOCK_PID=${process_pid}
LOCK_HOSTNAME=$(lease_lock_hostname)
LOCK_REPO_ROOT=${PWD}
LOCK_COMMAND=$(lease_lock_command_string "$process_pid")
LOCK_PROCESS_START=${process_start}
LOCK_ACQUIRED_AT_EPOCH=${LEASE_LOCK_ACQUIRED_AT_EPOCH:-$last_heartbeat_epoch}
LOCK_HEARTBEAT_EVERY_SEC=${LEASE_LOCK_HEARTBEAT_SECONDS}
LOCK_OWNER_STALE_AFTER_SEC=${LEASE_LOCK_OWNER_STALE_AFTER_SECONDS}
LOCK_WAITER_TIMEOUT_SEC=${LEASE_LOCK_WAITER_TIMEOUT_SECONDS}
LOCK_LEASE_TIMEOUT_SEC=${LEASE_LOCK_OWNER_STALE_AFTER_SECONDS}
LOCK_LAST_HEARTBEAT_EPOCH=${last_heartbeat_epoch}
LOCK_NEXT_HEARTBEAT_DUE_EPOCH=${next_due_epoch}
LOCK_STATE=${state}
EOF
}

lease_lock_metadata_value_from_file() {
  local metadata_file="$1"
  local key="$2"
  [[ -f "$metadata_file" ]] || return 1
  sed -n "s/^${key}=//p" "$metadata_file" | head -n 1
}

lease_lock_write_runtime_metadata_file() {
  local mutator_pid="$1"
  local mutator_command mutator_process_start

  [[ "$mutator_pid" =~ ^[0-9]+$ ]] || return 1
  mutator_command="$(lease_lock_command_string "$mutator_pid")"
  mutator_process_start="$(lease_lock_process_start_string "$mutator_pid" || true)"

  lease_lock_atomic_write_file "$LEASE_LOCK_OWNER_RUNTIME_FILE" <<EOF
LOCK_RUNTIME_VERSION=1
LOCK_RESOURCE=${LEASE_LOCK_RESOURCE}
LOCK_HOSTNAME=$(lease_lock_hostname)
LOCK_COMMON_REPO_ROOT=${LEASE_LOCK_COMMON_REPO_ROOT:-}
LOCK_MUTATOR_PID=${mutator_pid}
LOCK_MUTATOR_COMMAND=${mutator_command}
LOCK_MUTATOR_PROCESS_START=${mutator_process_start}
EOF
}

lease_lock_record_mutator_process() {
  local mutator_pid="$1"
  (( LEASE_LOCK_OWNS_LOCK == 1 )) || return 1
  lease_lock_write_runtime_metadata_file "$mutator_pid"
}

lease_lock_touch_heartbeat() {
  local heartbeat_file="$1"
  local metadata_file="$2"
  local owner_id="$3"
  local role="$4"
  local state="$5"
  local now_epoch next_due_epoch
  now_epoch="$(lease_lock_now_epoch)"
  next_due_epoch="$(lease_lock_next_due_epoch "$now_epoch")"
  lease_lock_atomic_write_file "$heartbeat_file" <<EOF
$now_epoch
EOF
  lease_lock_write_metadata_file \
    "$metadata_file" \
    "$owner_id" \
    "$role" \
    "$now_epoch" \
    "$next_due_epoch" \
    "$state"
}

lease_lock_start_heartbeat() {
  local heartbeat_file="$1"
  local metadata_file="$2"
  local owner_id="$3"
  local role="$4"
  local state="$5"
  local process_pid="${6:-$$}"
  if [[ ! -x "$LEASE_LOCK_HEARTBEAT_HELPER" ]]; then
    printf 'lease-lock heartbeat helper is not executable: %s\n' "$LEASE_LOCK_HEARTBEAT_HELPER" >&2
    return 1
  fi
  env LEASE_LOCK_TIMEOUT_SECONDS="$LEASE_LOCK_TIMEOUT_SECONDS" \
      LEASE_LOCK_OWNER_STALE_AFTER_SECONDS="$LEASE_LOCK_OWNER_STALE_AFTER_SECONDS" \
      LEASE_LOCK_WAITER_TIMEOUT_SECONDS="$LEASE_LOCK_WAITER_TIMEOUT_SECONDS" \
    "$LEASE_LOCK_HEARTBEAT_HELPER" \
      "$process_pid" \
      "$LEASE_LOCK_HEARTBEAT_SECONDS" \
      "$heartbeat_file" \
      "$metadata_file" \
      "$owner_id" \
      "$role" \
      "$state" \
      "$LEASE_LOCK_RESOURCE" \
      "$process_pid" \
      "${LEASE_LOCK_ACQUIRED_AT_EPOCH:-$(lease_lock_now_epoch)}" \
      "$PWD" >/dev/null 2>&1 &
  LEASE_LOCK_LAST_STARTED_HEARTBEAT_PID="$!"
}

lease_lock_owner_last_heartbeat_epoch() {
  if [[ -f "$LEASE_LOCK_OWNER_HEARTBEAT_FILE" ]]; then
    /bin/cat "$LEASE_LOCK_OWNER_HEARTBEAT_FILE" 2>/dev/null || true
    return 0
  fi
  if [[ -f "$LEASE_LOCK_OWNER_FILE" ]]; then
    sed -n 's/^LOCK_LAST_HEARTBEAT_EPOCH=//p' "$LEASE_LOCK_OWNER_FILE" | head -n 1
    return 0
  fi
  return 1
}

lease_lock_owner_metadata_value() {
  lease_lock_metadata_value_from_file "$LEASE_LOCK_OWNER_FILE" "$1"
}

lease_lock_owner_runtime_value() {
  lease_lock_metadata_value_from_file "$LEASE_LOCK_OWNER_RUNTIME_FILE" "$1"
}

lease_lock_process_alive_from_file() {
  local metadata_file="$1"
  local pid_key="$2"
  local start_key="$3"
  local command_key="$4"
  local process_pid process_start process_command

  process_pid="$(lease_lock_metadata_value_from_file "$metadata_file" "$pid_key" || true)"
  [[ "$process_pid" =~ ^[0-9]+$ ]] || return 1
  process_start="$(lease_lock_metadata_value_from_file "$metadata_file" "$start_key" || true)"
  process_command="$(lease_lock_metadata_value_from_file "$metadata_file" "$command_key" || true)"
  process_state_identity_matches "$process_pid" "$process_start" "$process_command"
}

lease_lock_owner_process_alive() {
  local owner_hostname runtime_hostname

  owner_hostname="$(lease_lock_owner_metadata_value LOCK_HOSTNAME || true)"
  if [[ -n "$owner_hostname" && "$owner_hostname" != "$(lease_lock_hostname)" ]]; then
    return 0
  fi

  if lease_lock_process_alive_from_file \
      "$LEASE_LOCK_OWNER_FILE" \
      LOCK_PID \
      LOCK_PROCESS_START \
      LOCK_COMMAND; then
    return 0
  fi

  runtime_hostname="$(lease_lock_owner_runtime_value LOCK_HOSTNAME || true)"
  if [[ -n "$runtime_hostname" && "$runtime_hostname" != "$(lease_lock_hostname)" ]]; then
    return 0
  fi

  lease_lock_process_alive_from_file \
    "$LEASE_LOCK_OWNER_RUNTIME_FILE" \
    LOCK_MUTATOR_PID \
    LOCK_MUTATOR_PROCESS_START \
    LOCK_MUTATOR_COMMAND
}

lease_lock_owner_summary() {
  local owner_summary mutator_pid mutator_command now_epoch

  if [[ ! -f "$LEASE_LOCK_OWNER_FILE" ]]; then
    return 1
  fi
  now_epoch="$(lease_lock_now_epoch)"
  owner_summary="$(awk -F= -v now_epoch="$now_epoch" '
    /^LOCK_OWNER_ID=/ { owner_id = $2 }
    /^LOCK_AGENT_ID=/ { agent_id = $2 }
    /^LOCK_PID=/ { pid = $2 }
    /^LOCK_COMMAND=/ { command = substr($0, index($0, "=") + 1) }
    /^LOCK_LAST_HEARTBEAT_EPOCH=/ { last = $2 }
    /^LOCK_NEXT_HEARTBEAT_DUE_EPOCH=/ { next_due = $2 }
    END {
      if (owner_id != "") {
        age_sec = (last == "" ? "?" : now_epoch - last)
        due_in_sec = (next_due == "" ? "?" : next_due - now_epoch)
        printf "owner_id=%s agent=%s pid=%s age_sec=%s due_in_sec=%s last_heartbeat=%s next_due=%s command=%s\n",
          owner_id, agent_id, pid, age_sec, due_in_sec, last, next_due, command
      }
    }
  ' "$LEASE_LOCK_OWNER_FILE")"
  [[ -n "$owner_summary" ]] || return 1

  mutator_pid="$(lease_lock_owner_runtime_value LOCK_MUTATOR_PID || true)"
  mutator_command="$(lease_lock_owner_runtime_value LOCK_MUTATOR_COMMAND || true)"
  if [[ "$mutator_pid" =~ ^[0-9]+$ ]]; then
    owner_summary="${owner_summary%$'\n'} mutator_pid=${mutator_pid}"
    if [[ -n "$mutator_command" ]]; then
      owner_summary="${owner_summary} mutator_command=${mutator_command}"
    fi
  fi

  printf '%s\n' "$owner_summary"
}

lease_lock_waiter_file_is_stale() {
  local waiter_file="$1"
  local last_heartbeat_epoch now_epoch

  last_heartbeat_epoch="$(lease_lock_metadata_value_from_file "$waiter_file" LOCK_LAST_HEARTBEAT_EPOCH || true)"
  [[ "$last_heartbeat_epoch" =~ ^[0-9]+$ ]] || return 0
  now_epoch="$(lease_lock_now_epoch)"
  (( now_epoch - last_heartbeat_epoch > LEASE_LOCK_WAITER_TIMEOUT_SECONDS ))
}

lease_lock_waiter_process_alive() {
  local waiter_file="$1"
  lease_lock_process_alive_from_file \
    "$waiter_file" \
    LOCK_PID \
    LOCK_PROCESS_START \
    LOCK_COMMAND
}

lease_lock_cleanup_stale_waiters() {
  local waiter_file waiter_heartbeat_file cleaned_count
  cleaned_count=0
  [[ -d "$LEASE_LOCK_WAITERS_DIR" ]] || return 0
  while IFS= read -r waiter_file; do
    [[ -n "$waiter_file" ]] || continue
    if lease_lock_waiter_process_alive "$waiter_file"; then
      continue
    fi
    if ! lease_lock_waiter_file_is_stale "$waiter_file"; then
      continue
    fi
    waiter_heartbeat_file="${waiter_file}.heartbeat"
    /bin/rm -f "$waiter_file" "$waiter_heartbeat_file"
    cleaned_count=$((cleaned_count + 1))
  done < <(find "$LEASE_LOCK_WAITERS_DIR" -type f -name '*.env' 2>/dev/null)

  if (( cleaned_count > 0 )); then
    printf 'Cleaned stale waiter metadata for %s lease at %s: removed=%s\n' \
      "$LEASE_LOCK_RESOURCE" "$LEASE_LOCK_DIR" "$cleaned_count" >&2
  fi
}

lease_lock_waiter_count() {
  if [[ ! -d "$LEASE_LOCK_WAITERS_DIR" ]]; then
    printf '0\n'
    return 0
  fi
  find "$LEASE_LOCK_WAITERS_DIR" -type f -name '*.env' | wc -l | tr -d ' '
}

lease_lock_remove_waiter() {
  if (( LEASE_LOCK_REGISTERED_WAITER == 1 )); then
    /bin/rm -f "$LEASE_LOCK_WAITER_FILE" "$LEASE_LOCK_WAITER_FILE.heartbeat"
    LEASE_LOCK_REGISTERED_WAITER=0
  fi
}

lease_lock_stop_waiter_heartbeat() {
  if [[ -n "$LEASE_LOCK_WAITER_HEARTBEAT_PID" ]]; then
    kill "$LEASE_LOCK_WAITER_HEARTBEAT_PID" 2>/dev/null || true
    wait "$LEASE_LOCK_WAITER_HEARTBEAT_PID" 2>/dev/null || true
    LEASE_LOCK_WAITER_HEARTBEAT_PID=""
  fi
}

lease_lock_stop_owner_heartbeat() {
  if [[ -n "$LEASE_LOCK_HEARTBEAT_PID" ]]; then
    kill "$LEASE_LOCK_HEARTBEAT_PID" 2>/dev/null || true
    wait "$LEASE_LOCK_HEARTBEAT_PID" 2>/dev/null || true
    LEASE_LOCK_HEARTBEAT_PID=""
  fi
}

lease_lock_cleanup() {
  lease_lock_stop_waiter_heartbeat
  lease_lock_remove_waiter
  lease_lock_stop_owner_heartbeat
  if (( LEASE_LOCK_OWNS_LOCK == 1 )); then
    /bin/rm -rf "$LEASE_LOCK_OWNER_DIR"
    LEASE_LOCK_OWNS_LOCK=0
  fi
}

lease_lock_register_waiter() {
  /bin/mkdir -p "$LEASE_LOCK_WAITERS_DIR"
  LEASE_LOCK_ACQUIRED_AT_EPOCH="$(lease_lock_now_epoch)"
  LEASE_LOCK_PROCESS_PID="$$"
  lease_lock_touch_heartbeat \
    "$LEASE_LOCK_WAITER_FILE.heartbeat" \
    "$LEASE_LOCK_WAITER_FILE" \
    "$LEASE_LOCK_WAITER_ID" \
    "waiter" \
    "waiting"
  lease_lock_start_heartbeat \
    "$LEASE_LOCK_WAITER_FILE.heartbeat" \
    "$LEASE_LOCK_WAITER_FILE" \
    "$LEASE_LOCK_WAITER_ID" \
    "waiter" \
    "waiting" \
    "$$"
  LEASE_LOCK_WAITER_HEARTBEAT_PID="$LEASE_LOCK_LAST_STARTED_HEARTBEAT_PID"
  LEASE_LOCK_REGISTERED_WAITER=1
}

lease_lock_unregister_waiter() {
  lease_lock_stop_waiter_heartbeat
  /bin/rm -f "$LEASE_LOCK_WAITER_FILE" "$LEASE_LOCK_WAITER_FILE.heartbeat"
  LEASE_LOCK_REGISTERED_WAITER=0
}

lease_lock_try_acquire_owner_dir() {
  if /bin/mkdir "$LEASE_LOCK_OWNER_DIR" 2>/dev/null; then
    LEASE_LOCK_OWNER_ID="${LEASE_LOCK_OWNER_ID:-$$-$(lease_lock_now_epoch)}"
    LEASE_LOCK_ACQUIRED_AT_EPOCH="$(lease_lock_now_epoch)"
    LEASE_LOCK_PROCESS_PID="$$"
    lease_lock_touch_heartbeat \
      "$LEASE_LOCK_OWNER_HEARTBEAT_FILE" \
      "$LEASE_LOCK_OWNER_FILE" \
      "$LEASE_LOCK_OWNER_ID" \
      "owner" \
      "holding"
    lease_lock_start_heartbeat \
      "$LEASE_LOCK_OWNER_HEARTBEAT_FILE" \
      "$LEASE_LOCK_OWNER_FILE" \
      "$LEASE_LOCK_OWNER_ID" \
      "owner" \
      "holding" \
      "$$"
    LEASE_LOCK_HEARTBEAT_PID="$LEASE_LOCK_LAST_STARTED_HEARTBEAT_PID"
    LEASE_LOCK_OWNS_LOCK=1
    return 0
  fi
  return 1
}

lease_lock_try_reclaim_stale_owner() {
  local now_epoch owner_last_heartbeat reclaim_dir
  [[ -d "$LEASE_LOCK_OWNER_DIR" ]] || return 1
  owner_last_heartbeat="$(lease_lock_owner_last_heartbeat_epoch || true)"
  [[ -n "$owner_last_heartbeat" ]] || owner_last_heartbeat=0
  now_epoch="$(lease_lock_now_epoch)"
  if ! lease_lock_is_expired_epoch "$owner_last_heartbeat" "$now_epoch"; then
    return 1
  fi

  # Treat a stalled heartbeat helper as degraded, not dead, while the recorded
  # owner process is still alive on this host. That prevents overlapping owners
  # from reclaiming the lease during transient heartbeat gaps.
  if lease_lock_owner_process_alive; then
    return 1
  fi

  reclaim_dir="${LEASE_LOCK_DIR}/reclaimed-${LEASE_LOCK_WAITER_ID}-${now_epoch}"
  if /bin/mv "$LEASE_LOCK_OWNER_DIR" "$reclaim_dir" 2>/dev/null; then
    /bin/rm -rf "$reclaim_dir"
    return 0
  fi
  return 1
}

lease_lock_acquire() {
  local started_at now_epoch last_reported_summary last_status_epoch
  /bin/mkdir -p "$LEASE_LOCK_WAITERS_DIR"
  lease_lock_cleanup_stale_waiters
  lease_lock_register_waiter
  started_at="$(lease_lock_now_epoch)"
  last_status_epoch="$started_at"
  last_reported_summary=""
  while ! lease_lock_try_acquire_owner_dir; do
    lease_lock_cleanup_stale_waiters
    if lease_lock_try_reclaim_stale_owner; then
      continue
    fi

    local owner_summary waiter_count
    owner_summary="$(lease_lock_owner_summary || true)"
    waiter_count="$(lease_lock_waiter_count)"
    now_epoch="$(lease_lock_now_epoch)"
    if [[ "$owner_summary" != "$last_reported_summary" ]] \
      || (( now_epoch - last_status_epoch >= 15 )); then
      printf 'Waiting for %s lease at %s\n' "$LEASE_LOCK_RESOURCE" "$LEASE_LOCK_DIR" >&2
      if [[ -n "$owner_summary" ]]; then
        printf 'lease owner: %s\n' "$owner_summary" >&2
      fi
      printf 'active waiters: %s\n' "$waiter_count" >&2
      last_reported_summary="$owner_summary"
      last_status_epoch="$now_epoch"
    fi

    if (( LEASE_LOCK_WAITER_TIMEOUT_SECONDS > 0 )) \
      && (( now_epoch - started_at >= LEASE_LOCK_WAITER_TIMEOUT_SECONDS )); then
      printf 'Timed out waiting for %s lease at %s\n' "$LEASE_LOCK_RESOURCE" "$LEASE_LOCK_DIR" >&2
      if [[ -n "$owner_summary" ]]; then
        printf 'timeout owner summary: %s\n' "$owner_summary" >&2
      fi
      printf 'timeout waiters observed: %s\n' "$waiter_count" >&2
      return 1
    fi
    sleep "$LEASE_LOCK_POLL_SECONDS"
  done
  lease_lock_unregister_waiter
}
