#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
readonly ROOT
RUN_ID="$$"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/lease-lock-test-$RUN_ID.XXXXXX")"
PASS_COUNT=0
FAIL_COUNT=0
FAIL_NAMES=()
CURRENT_TEST=""
SPAWNED_PIDS=()

cleanup() {
  local pid
  for pid in "${SPAWNED_PIDS[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

log() {
  printf '%s\n' "$*" >&2
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  log "  PASS: $CURRENT_TEST"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAIL_NAMES+=("$CURRENT_TEST")
  log "  FAIL: $CURRENT_TEST - $*"
}

start_test() {
  CURRENT_TEST="$1"
  log "RUN:  $CURRENT_TEST"
}

wait_for_path() {
  local path="$1"
  local attempts="${2:-60}"
  local delay="${3:-0.1}"
  local index=0
  while (( index < attempts )); do
    if [[ -e "$path" ]]; then
      return 0
    fi
    sleep "$delay"
    index=$((index + 1))
  done
  return 1
}

wait_for_missing_path() {
  local path="$1"
  local attempts="${2:-60}"
  local delay="${3:-0.1}"
  local index=0
  while (( index < attempts )); do
    if [[ ! -e "$path" ]]; then
      return 0
    fi
    sleep "$delay"
    index=$((index + 1))
  done
  return 1
}

wait_for_file_change() {
  local path="$1"
  local original="$2"
  local attempts="${3:-80}"
  local delay="${4:-0.1}"
  local index=0
  local current=""
  while (( index < attempts )); do
    current="$(cat "$path" 2>/dev/null || true)"
    if [[ -n "$current" && "$current" != "$original" ]]; then
      printf '%s\n' "$current"
      return 0
    fi
    sleep "$delay"
    index=$((index + 1))
  done
  return 1
}

with_lock_env() {
  local lock_dir="$1"
  shift
  env \
    LOCK_HELPER_PATH="$ROOT/scripts/lib/lease-lock.sh" \
    LEASE_LOCK_DIR="$lock_dir" \
    LEASE_LOCK_RESOURCE="test-resource" \
    LEASE_LOCK_HEARTBEAT_SECONDS=1 \
    LEASE_LOCK_TIMEOUT_SECONDS=8 \
    LEASE_LOCK_POLL_SECONDS=1 \
    "$@"
}

scenario_acquire_release() {
  start_test "lease lock acquires and releases owner metadata"
  local lock_dir="$SANDBOX/acquire-release"

  # shellcheck disable=SC2016
  with_lock_env "$lock_dir" bash -c '
    set -euo pipefail
    source "$LOCK_HELPER_PATH"
    lease_lock_acquire
    [[ -f "$LEASE_LOCK_OWNER_FILE" ]]
    grep -q "^LOCK_STATE=holding$" "$LEASE_LOCK_OWNER_FILE"
    lease_lock_cleanup
  '

  if [[ -e "$lock_dir/owner" ]]; then
    fail "owner dir still exists after cleanup"
    return
  fi
  pass
}

scenario_waiter_cleanup_removes_heartbeat() {
  start_test "lease lock cleanup removes waiter heartbeat sidecars"
  local lock_dir="$SANDBOX/waiter-cleanup"

  if ! with_lock_env "$lock_dir" bash -c '
    set -euo pipefail
    export LEASE_LOCK_WAITER_ID=waiter-cleanup
    source "$LOCK_HELPER_PATH"
    lease_lock_register_waiter
    [[ -f "$LEASE_LOCK_WAITER_FILE" ]]
    [[ -f "$LEASE_LOCK_WAITER_FILE.heartbeat" ]]
    lease_lock_cleanup
    [[ ! -e "$LEASE_LOCK_WAITER_FILE" ]]
    [[ ! -e "$LEASE_LOCK_WAITER_FILE.heartbeat" ]]
  '; then
    fail "waiter cleanup left metadata behind"
    return
  fi

  pass
}

scenario_waiter_observes_live_heartbeat() {
  start_test "waiter observes live owner heartbeat and acquires after release"
  local lock_dir="$SANDBOX/live-heartbeat"
  local owner_ready="$SANDBOX/live-heartbeat.owner-ready"
  local waiter_acquired="$SANDBOX/live-heartbeat.waiter-acquired"
  local waiter_file="$lock_dir/waiters/waiter-one.env"
  local waiter_heartbeat_file="$waiter_file.heartbeat"

  # shellcheck disable=SC2016
  with_lock_env "$lock_dir" bash -c '
    set -euo pipefail
    export LEASE_LOCK_WAITER_ID=owner-one
    source "$LOCK_HELPER_PATH"
    lease_lock_acquire
    : >"'"$owner_ready"'"
    sleep 4
    lease_lock_cleanup
  ' &
  local owner_pid=$!
  SPAWNED_PIDS+=("$owner_pid")

  wait_for_path "$owner_ready" || { fail "owner never acquired"; return; }
  wait_for_path "$lock_dir/owner/lease.env" || { fail "owner metadata missing"; return; }
  local first_heartbeat
  first_heartbeat="$(cat "$lock_dir/owner/heartbeat" 2>/dev/null || true)"
  if [[ -z "$first_heartbeat" ]]; then
    fail "initial owner heartbeat missing"
    return
  fi

  # shellcheck disable=SC2016
  with_lock_env "$lock_dir" bash -c '
    set -euo pipefail
    export LEASE_LOCK_WAITER_ID=waiter-one
    source "$LOCK_HELPER_PATH"
    lease_lock_acquire
    : >"'"$waiter_acquired"'"
    lease_lock_cleanup
  ' &
  local waiter_pid=$!
  SPAWNED_PIDS+=("$waiter_pid")

  wait_for_path "$waiter_file" || { fail "waiter metadata missing while blocked"; return; }
  local updated_heartbeat
  updated_heartbeat="$(wait_for_file_change "$lock_dir/owner/heartbeat" "$first_heartbeat")" || {
    fail "owner heartbeat did not refresh while waiter was blocked"
    return
  }
  if (( updated_heartbeat <= first_heartbeat )); then
    fail "owner heartbeat did not advance"
    return
  fi

  wait "$owner_pid"
  wait_for_path "$waiter_acquired" || { fail "waiter never acquired after owner release"; return; }
  wait "$waiter_pid"

  if [[ -e "$waiter_file" ]]; then
    fail "waiter metadata still exists after acquisition"
    return
  fi
  if [[ -e "$waiter_heartbeat_file" ]]; then
    fail "waiter heartbeat still exists after acquisition"
    return
  fi
  pass
}

scenario_stale_owner_reclaimed() {
  start_test "stale owner lease is reclaimed after timeout"
  local lock_dir="$SANDBOX/stale-reclaim"
  mkdir -p "$lock_dir/owner" "$lock_dir/waiters"
  cat >"$lock_dir/owner/lease.env" <<EOF
LOCK_PROTOCOL_VERSION=1
LOCK_RESOURCE=test-resource
LOCK_ROLE=owner
LOCK_OWNER_ID=stale-owner
LOCK_AGENT_ID=test
LOCK_PID=999999
LOCK_HOSTNAME=test-host
LOCK_REPO_ROOT=$ROOT
LOCK_COMMAND=stale
LOCK_ACQUIRED_AT_EPOCH=1
LOCK_HEARTBEAT_EVERY_SEC=1
LOCK_LEASE_TIMEOUT_SEC=3
LOCK_LAST_HEARTBEAT_EPOCH=1
LOCK_NEXT_HEARTBEAT_DUE_EPOCH=2
LOCK_STATE=holding
EOF
  printf '1\n' >"$lock_dir/owner/heartbeat"

  # shellcheck disable=SC2016
  with_lock_env "$lock_dir" bash -c '
    set -euo pipefail
    export LEASE_LOCK_WAITER_ID=reclaimer-one
    source "$LOCK_HELPER_PATH"
    lease_lock_acquire
    grep -q "^LOCK_OWNER_ID=" "$LEASE_LOCK_OWNER_FILE"
    if grep -q "^LOCK_OWNER_ID=stale-owner$" "$LEASE_LOCK_OWNER_FILE"; then
      exit 1
    fi
    lease_lock_cleanup
  ' || {
    fail "reclaimer did not take over stale lease"
    return
  }

  pass
}

scenario_live_owner_with_stale_heartbeat_not_reclaimed() {
  start_test "stale owner heartbeat is not reclaimed while owner pid is alive"
  local lock_dir="$SANDBOX/live-owner-stale-heartbeat"
  local owner_command owner_hostname
  mkdir -p "$lock_dir/owner" "$lock_dir/waiters"

  /bin/sleep 300 &
  local owner_pid=$!
  SPAWNED_PIDS+=("$owner_pid")
  owner_command="$(ps -p "$owner_pid" -o command= 2>/dev/null | sed 's/^[[:space:]]*//' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/[[:space:]]$//')"
  owner_hostname="$(/bin/hostname)"

  cat >"$lock_dir/owner/lease.env" <<EOF
LOCK_PROTOCOL_VERSION=1
LOCK_RESOURCE=test-resource
LOCK_ROLE=owner
LOCK_OWNER_ID=live-owner
LOCK_AGENT_ID=test
LOCK_PID=$owner_pid
LOCK_HOSTNAME=$owner_hostname
LOCK_REPO_ROOT=$ROOT
LOCK_COMMAND=$owner_command
LOCK_ACQUIRED_AT_EPOCH=1
LOCK_HEARTBEAT_EVERY_SEC=1
LOCK_LEASE_TIMEOUT_SEC=3
LOCK_LAST_HEARTBEAT_EPOCH=1
LOCK_NEXT_HEARTBEAT_DUE_EPOCH=2
LOCK_STATE=holding
EOF
  printf '1\n' >"$lock_dir/owner/heartbeat"

  if ! with_lock_env "$lock_dir" bash -c '
    set -euo pipefail
    export LEASE_LOCK_WAITER_ID=waiter-live-owner
    source "$LOCK_HELPER_PATH"
    if lease_lock_try_reclaim_stale_owner; then
      exit 1
    fi
  '; then
    fail "stale owner was reclaimed despite a live owner pid"
    return
  fi

  if [[ ! -d "$lock_dir/owner" ]]; then
    fail "owner dir was removed while live owner pid still existed"
    return
  fi

  pass
}

scenario_active_owner_not_hijacked() {
  start_test "active owner lease is not hijacked by parallel waiter"
  local lock_dir="$SANDBOX/no-hijack"
  local owner_ready="$SANDBOX/no-hijack.owner-ready"
  local owner_done="$SANDBOX/no-hijack.owner-done"
  local waiter_done="$SANDBOX/no-hijack.waiter-done"

  # shellcheck disable=SC2016
  with_lock_env "$lock_dir" bash -c '
    set -euo pipefail
    export LEASE_LOCK_WAITER_ID=owner-two
    source "$LOCK_HELPER_PATH"
    lease_lock_acquire
    : >"'"$owner_ready"'"
    sleep 3
    : >"'"$owner_done"'"
    lease_lock_cleanup
  ' &
  local owner_pid=$!
  SPAWNED_PIDS+=("$owner_pid")
  wait_for_path "$owner_ready" || { fail "owner did not start"; return; }

  # shellcheck disable=SC2016
  with_lock_env "$lock_dir" bash -c '
    set -euo pipefail
    export LEASE_LOCK_WAITER_ID=waiter-two
    source "$LOCK_HELPER_PATH"
    lease_lock_acquire
    : >"'"$waiter_done"'"
    lease_lock_cleanup
  ' &
  local waiter_pid=$!
  SPAWNED_PIDS+=("$waiter_pid")

  sleep 1
  if [[ -e "$waiter_done" ]]; then
    fail "waiter acquired before active owner released"
    return
  fi

  wait "$owner_pid"
  wait_for_path "$owner_done" || { fail "owner completion marker missing"; return; }
  wait_for_path "$waiter_done" || { fail "waiter never acquired after owner release"; return; }
  wait "$waiter_pid"
  pass
}

run_all() {
  scenario_acquire_release
  scenario_waiter_cleanup_removes_heartbeat
  scenario_waiter_observes_live_heartbeat
  scenario_stale_owner_reclaimed
  scenario_live_owner_with_stale_heartbeat_not_reclaimed
  scenario_active_owner_not_hijacked
}

run_all

log "----"
log "lease-lock tests: $PASS_COUNT passed, $FAIL_COUNT failed"
if (( FAIL_COUNT > 0 )); then
  log "failures:"
  for name in "${FAIL_NAMES[@]}"; do
    log "  - $name"
  done
  exit 1
fi
