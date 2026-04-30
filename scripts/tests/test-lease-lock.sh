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

scenario_heartbeat_helper_exits_when_owner_dir_is_removed() {
  start_test "lease lock heartbeat helper exits quietly when owner dir disappears"
  local lock_dir="$SANDBOX/heartbeat-helper-race"
  local owner_dir="$lock_dir/owner"
  local heartbeat_file="$owner_dir/heartbeat"
  local metadata_file="$owner_dir/lease.env"
  local helper_pid target_pid

  mkdir -p "$owner_dir"
  cat >"$metadata_file" <<EOF
LOCK_PROTOCOL_VERSION=1
LOCK_RESOURCE=test-resource
LOCK_ROLE=owner
LOCK_OWNER_ID=owner-helper
LOCK_AGENT_ID=test
LOCK_PID=$$
LOCK_HOSTNAME=$(hostname)
LOCK_REPO_ROOT=$ROOT
LOCK_COMMAND=test
LOCK_ACQUIRED_AT_EPOCH=$(date +%s)
LOCK_HEARTBEAT_EVERY_SEC=1
LOCK_OWNER_STALE_AFTER_SEC=8
LOCK_WAITER_TIMEOUT_SEC=9
LOCK_LEASE_TIMEOUT_SEC=8
LOCK_LAST_HEARTBEAT_EPOCH=$(date +%s)
LOCK_NEXT_HEARTBEAT_DUE_EPOCH=$(( $(date +%s) + 1 ))
LOCK_STATE=holding
EOF
  printf '0\n' >"$heartbeat_file"

  /bin/sleep 300 &
  target_pid=$!
  SPAWNED_PIDS+=("$target_pid")

  "$ROOT/scripts/lib/lease-lock-heartbeat.sh" \
    "$target_pid" \
    1 \
    "$heartbeat_file" \
    "$metadata_file" \
    owner-helper \
    owner \
    holding \
    test-resource \
    "$target_pid" \
    "$(date +%s)" \
    "$ROOT" >/dev/null 2>&1 &
  helper_pid=$!
  SPAWNED_PIDS+=("$helper_pid")

  wait_for_file_change "$heartbeat_file" "0" || {
    fail "heartbeat helper never refreshed the owner heartbeat"
    return
  }

  rm -rf "$owner_dir"

  if ! wait "$helper_pid"; then
    fail "heartbeat helper surfaced an error after owner dir cleanup"
    return
  fi

  if [[ -e "$owner_dir" ]]; then
    fail "heartbeat helper recreated the owner dir after cleanup"
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
  local owner_hostname
  owner_hostname="$(/bin/hostname)"
  mkdir -p "$lock_dir/owner" "$lock_dir/waiters"
  cat >"$lock_dir/owner/lease.env" <<EOF
LOCK_PROTOCOL_VERSION=1
LOCK_RESOURCE=test-resource
LOCK_ROLE=owner
LOCK_OWNER_ID=stale-owner
LOCK_AGENT_ID=test
LOCK_PID=999999
LOCK_HOSTNAME=$owner_hostname
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

scenario_waiter_reclaims_after_owner_becomes_stale_while_waiting() {
  start_test "waiting waiter reclaims once owner ages past stale timeout"
  local lock_dir="$SANDBOX/stale-while-waiting"
  local now_epoch owner_hostname
  owner_hostname="$(/bin/hostname)"
  now_epoch="$(date +%s)"
  mkdir -p "$lock_dir/owner" "$lock_dir/waiters"
  cat >"$lock_dir/owner/lease.env" <<EOF
LOCK_PROTOCOL_VERSION=1
LOCK_RESOURCE=test-resource
LOCK_ROLE=owner
LOCK_OWNER_ID=stale-later-owner
LOCK_AGENT_ID=test
LOCK_PID=999999
LOCK_HOSTNAME=$owner_hostname
LOCK_REPO_ROOT=$ROOT
LOCK_COMMAND=stale
LOCK_ACQUIRED_AT_EPOCH=$now_epoch
LOCK_HEARTBEAT_EVERY_SEC=1
LOCK_OWNER_STALE_AFTER_SEC=2
LOCK_WAITER_TIMEOUT_SEC=5
LOCK_LEASE_TIMEOUT_SEC=2
LOCK_LAST_HEARTBEAT_EPOCH=$now_epoch
LOCK_NEXT_HEARTBEAT_DUE_EPOCH=$((now_epoch + 1))
LOCK_STATE=holding
EOF
  printf '%s\n' "$now_epoch" >"$lock_dir/owner/heartbeat"

  if ! with_lock_env "$lock_dir" env \
      LEASE_LOCK_OWNER_STALE_AFTER_SECONDS=2 \
      LEASE_LOCK_WAITER_TIMEOUT_SECONDS=5 \
      LEASE_LOCK_POLL_SECONDS=1 \
      bash -c '
        set -euo pipefail
        export LEASE_LOCK_WAITER_ID=waiter-stale-later
        source "$LOCK_HELPER_PATH"
        lease_lock_acquire
        if grep -q "^LOCK_OWNER_ID=stale-later-owner$" "$LEASE_LOCK_OWNER_FILE"; then
          exit 1
        fi
        lease_lock_cleanup
      '; then
    fail "waiter did not reclaim once the owner became stale"
    return
  fi

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

scenario_live_mutator_with_dead_owner_not_reclaimed() {
  start_test "stale owner is not reclaimed while recorded mutator pid is still alive"
  local lock_dir="$SANDBOX/live-mutator-stale-owner"
  local mutator_command mutator_start owner_hostname
  mkdir -p "$lock_dir/owner" "$lock_dir/waiters"

  /bin/sleep 300 &
  local mutator_pid=$!
  SPAWNED_PIDS+=("$mutator_pid")
  mutator_command="$(ps -p "$mutator_pid" -o command= 2>/dev/null | sed 's/^[[:space:]]*//' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/[[:space:]]$//')"
  mutator_start="$(ps -p "$mutator_pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]\+/ /g; s/[[:space:]]$//')"
  owner_hostname="$(/bin/hostname)"

  cat >"$lock_dir/owner/lease.env" <<EOF
LOCK_PROTOCOL_VERSION=1
LOCK_RESOURCE=test-resource
LOCK_ROLE=owner
LOCK_OWNER_ID=dead-owner-live-mutator
LOCK_AGENT_ID=test
LOCK_PID=999999
LOCK_HOSTNAME=$owner_hostname
LOCK_REPO_ROOT=$ROOT
LOCK_COMMAND=stale
LOCK_ACQUIRED_AT_EPOCH=1
LOCK_HEARTBEAT_EVERY_SEC=1
LOCK_OWNER_STALE_AFTER_SEC=3
LOCK_WAITER_TIMEOUT_SEC=6
LOCK_LEASE_TIMEOUT_SEC=3
LOCK_LAST_HEARTBEAT_EPOCH=1
LOCK_NEXT_HEARTBEAT_DUE_EPOCH=2
LOCK_STATE=holding
EOF
  cat >"$lock_dir/owner/runtime.env" <<EOF
LOCK_RUNTIME_VERSION=1
LOCK_RESOURCE=test-resource
LOCK_HOSTNAME=$owner_hostname
LOCK_COMMON_REPO_ROOT=$ROOT
LOCK_MUTATOR_PID=$mutator_pid
LOCK_MUTATOR_COMMAND=$mutator_command
LOCK_MUTATOR_PROCESS_START=$mutator_start
EOF
  printf '1\n' >"$lock_dir/owner/heartbeat"

  if ! with_lock_env "$lock_dir" bash -c '
    set -euo pipefail
    export LEASE_LOCK_WAITER_ID=waiter-live-mutator
    source "$LOCK_HELPER_PATH"
    if lease_lock_try_reclaim_stale_owner; then
      exit 1
    fi
  '; then
    fail "stale owner was reclaimed despite a live mutator pid"
    return
  fi

  if [[ ! -d "$lock_dir/owner" ]]; then
    fail "owner dir was removed while live mutator pid still existed"
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

scenario_stale_waiter_metadata_is_cleaned() {
  start_test "stale dead waiter metadata is pruned before acquisition"
  local lock_dir="$SANDBOX/stale-waiter-cleanup"
  local now_epoch
  mkdir -p "$lock_dir/waiters"
  now_epoch="$(date +%s)"
  cat >"$lock_dir/waiters/stale-dead.env" <<EOF
LOCK_PROTOCOL_VERSION=1
LOCK_RESOURCE=test-resource
LOCK_ROLE=waiter
LOCK_OWNER_ID=stale-dead
LOCK_AGENT_ID=test
LOCK_PID=999999
LOCK_HOSTNAME=$(hostname)
LOCK_REPO_ROOT=$ROOT
LOCK_COMMAND=stale-waiter
LOCK_PROCESS_START=
LOCK_ACQUIRED_AT_EPOCH=1
LOCK_HEARTBEAT_EVERY_SEC=1
LOCK_OWNER_STALE_AFTER_SEC=2
LOCK_WAITER_TIMEOUT_SEC=2
LOCK_LEASE_TIMEOUT_SEC=2
LOCK_LAST_HEARTBEAT_EPOCH=$((now_epoch - 20))
LOCK_NEXT_HEARTBEAT_DUE_EPOCH=$((now_epoch - 19))
LOCK_STATE=waiting
EOF
  printf '%s\n' "$((now_epoch - 20))" >"$lock_dir/waiters/stale-dead.env.heartbeat"

  # shellcheck disable=SC2016
  if ! with_lock_env "$lock_dir" env \
      LEASE_LOCK_WAITER_TIMEOUT_SECONDS=2 \
      bash -c '
        set -euo pipefail
        export LEASE_LOCK_WAITER_ID=cleanup-owner
        source "$LOCK_HELPER_PATH"
        lease_lock_acquire
        [[ ! -e "$LEASE_LOCK_WAITERS_DIR/stale-dead.env" ]]
        [[ ! -e "$LEASE_LOCK_WAITERS_DIR/stale-dead.env.heartbeat" ]]
        lease_lock_cleanup
      '; then
    fail "stale waiter metadata was not pruned"
    return
  fi

  pass
}

scenario_wait_timeout_reports_owner_details() {
  start_test "wait timeout includes owner summary details"
  local lock_dir="$SANDBOX/wait-timeout-owner-summary"
  local now_epoch owner_hostname timeout_output
  owner_hostname="$(/bin/hostname)"
  now_epoch="$(date +%s)"
  mkdir -p "$lock_dir/owner" "$lock_dir/waiters"
  cat >"$lock_dir/owner/lease.env" <<EOF
LOCK_PROTOCOL_VERSION=1
LOCK_RESOURCE=test-resource
LOCK_ROLE=owner
LOCK_OWNER_ID=timeout-owner
LOCK_AGENT_ID=test
LOCK_PID=999999
LOCK_HOSTNAME=$owner_hostname
LOCK_REPO_ROOT=$ROOT
LOCK_COMMAND=timeout-holder
LOCK_ACQUIRED_AT_EPOCH=$now_epoch
LOCK_HEARTBEAT_EVERY_SEC=1
LOCK_OWNER_STALE_AFTER_SEC=30
LOCK_WAITER_TIMEOUT_SEC=2
LOCK_LEASE_TIMEOUT_SEC=30
LOCK_LAST_HEARTBEAT_EPOCH=$now_epoch
LOCK_NEXT_HEARTBEAT_DUE_EPOCH=$((now_epoch + 1))
LOCK_STATE=holding
EOF
  printf '%s\n' "$now_epoch" >"$lock_dir/owner/heartbeat"

  # shellcheck disable=SC2016
  timeout_output="$(
    with_lock_env "$lock_dir" env \
      LEASE_LOCK_OWNER_STALE_AFTER_SECONDS=30 \
      LEASE_LOCK_WAITER_TIMEOUT_SECONDS=2 \
      LEASE_LOCK_POLL_SECONDS=1 \
      bash -c '
        set -euo pipefail
        export LEASE_LOCK_WAITER_ID=timeout-waiter
        source "$LOCK_HELPER_PATH"
        lease_lock_acquire
      ' 2>&1 || true
  )"

  if ! grep -q "Timed out waiting for test-resource lease at $lock_dir" <<<"$timeout_output"; then
    fail "missing timeout headline"
    return
  fi
  if ! grep -q "timeout owner summary: owner_id=timeout-owner" <<<"$timeout_output"; then
    fail "missing owner summary in timeout output"
    return
  fi
  if ! grep -q "timeout waiters observed:" <<<"$timeout_output"; then
    fail "missing waiter count in timeout output"
    return
  fi
  pass
}

run_all() {
  scenario_acquire_release
  scenario_waiter_cleanup_removes_heartbeat
  scenario_heartbeat_helper_exits_when_owner_dir_is_removed
  scenario_waiter_observes_live_heartbeat
  scenario_stale_owner_reclaimed
  scenario_waiter_reclaims_after_owner_becomes_stale_while_waiting
  scenario_live_owner_with_stale_heartbeat_not_reclaimed
  scenario_live_mutator_with_dead_owner_not_reclaimed
  scenario_active_owner_not_hijacked
  scenario_stale_waiter_metadata_is_cleaned
  scenario_wait_timeout_reports_owner_details
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
