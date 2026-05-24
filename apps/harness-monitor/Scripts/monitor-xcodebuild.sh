#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="${HARNESS_MONITOR_APP_ROOT:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)}"
CHECKOUT_ROOT="$(CDPATH='' cd -- "$ROOT/../.." && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$CHECKOUT_ROOT/scripts/lib/common-repo-root.sh"
COMMON_REPO_ROOT="$(resolve_common_repo_root "$CHECKOUT_ROOT")"
CALLER_PWD="$(pwd -P)"
# shellcheck source=apps/harness-monitor/Scripts/lib/monitor-lanes.sh
source "$SCRIPT_DIR/lib/monitor-lanes.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/non-indexable-roots.sh
source "$SCRIPT_DIR/lib/non-indexable-roots.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/rtk-shell.sh
source "$SCRIPT_DIR/lib/rtk-shell.sh"

STALE_CHECK_SCRIPT="$CHECKOUT_ROOT/scripts/check-no-stale-state.sh"
FAILURE_REPORT_DIR="${HARNESS_MONITOR_FAILURE_REPORT_DIR:-$COMMON_REPO_ROOT/tmp/scan}"
LOCK_WAIT_TIMEOUT_SECONDS="${XCODEBUILD_LOCK_WAIT_TIMEOUT_SECONDS:-15}"
GLOBAL_SEMAPHORE_DIR="${HARNESS_MONITOR_GLOBAL_SEMAPHORE_DIR:-$COMMON_REPO_ROOT/.cache/harness-monitor-xcodebuild-semaphore}"

# The cap is hardcoded -- automated agents must NOT be able to bypass the
# host-protection semaphore by exporting an env var. An agent that thinks
# it "needs another slot" is exactly the failure case this defends against
# (observed: an agent set HARNESS_MONITOR_BUILD_GLOBAL_CONCURRENCY=8
# unilaterally because it judged the host as idle). If the *user* wants to
# raise the cap, edit this constant; the diff is visible in git history.
#
# Cap=2: on a 14-core M3 Max one Monitor build saturates ~10 cores; two
# concurrent fit while leaving the system responsive. Three+ pushed load
# average past 80 in observed runs. User-set ceiling.
GLOBAL_CONCURRENCY=2
# Test-only override path. Requires THREE env vars set together so it
# cannot be tripped by a single accidental export:
#   _HARNESS_INTERNAL_TEST_ONLY_CONCURRENCY=<N>
#   _HARNESS_INTERNAL_TEST_ONLY_AUTHORIZED=I_understand_this_breaks_host_protection
#   _HARNESS_INTERNAL_TEST_ONLY_RUNNER_PID=<test runner pid; must equal $PPID>
# The runner-PID check raises the bar above "find the env name and set
# it": the override only fires if the calling process's PID matches the
# value the caller declared. Unit tests can satisfy this trivially with
# os.getpid() at subprocess.run time; agents would have to know and
# accurately predict the wrapper's parent PID. When applied, the
# wrapper logs a loud stderr warning so any review of CI/build output
# surfaces the bypass.
_test_override="${_HARNESS_INTERNAL_TEST_ONLY_CONCURRENCY:-}"
if [[ -n "$_test_override" ]]; then
  _auth="${_HARNESS_INTERNAL_TEST_ONLY_AUTHORIZED:-}"
  _runner_pid="${_HARNESS_INTERNAL_TEST_ONLY_RUNNER_PID:-0}"
  if [[ "$_auth" == "I_understand_this_breaks_host_protection" ]] \
      && [[ "$_runner_pid" == "$PPID" ]]; then
    GLOBAL_CONCURRENCY="$_test_override"
    printf 'monitor-xcodebuild: WARN: test-only concurrency override applied (cap=%d). This env path is reserved for unit tests; production agents must not use it.\n' \
      "$GLOBAL_CONCURRENCY" >&2
  else
    printf 'monitor-xcodebuild: _HARNESS_INTERNAL_TEST_ONLY_CONCURRENCY="%s" ignored: missing _HARNESS_INTERNAL_TEST_ONLY_AUTHORIZED or runner-pid mismatch (expected PPID=%s).\n' \
      "$_test_override" "$PPID" >&2
  fi
fi
unset _test_override _auth _runner_pid
# Backwards-compat: warn if the old plain test env was set so anything in
# CI that still references it surfaces the change.
if [[ -n "${_HARNESS_TEST_GLOBAL_CONCURRENCY_OVERRIDE:-}" ]]; then
  printf 'monitor-xcodebuild: _HARNESS_TEST_GLOBAL_CONCURRENCY_OVERRIDE is no longer honored. Use the new triple _HARNESS_INTERNAL_TEST_ONLY_{CONCURRENCY,AUTHORIZED,RUNNER_PID}.\n' >&2
fi
if [[ -n "${HARNESS_MONITOR_BUILD_GLOBAL_CONCURRENCY:-}" ]]; then
  printf 'monitor-xcodebuild: HARNESS_MONITOR_BUILD_GLOBAL_CONCURRENCY="%s" is ignored; the cap is hardcoded to %d to prevent automated bypass. Edit Scripts/monitor-xcodebuild.sh if a different cap is intended.\n' \
    "$HARNESS_MONITOR_BUILD_GLOBAL_CONCURRENCY" "$GLOBAL_CONCURRENCY" >&2
fi

# Heartbeat refreshed by the slot owner. Other wrappers use mtime freshness
# to decide whether the slot is still active (stops a hung wrapper from
# camping forever). Interval is short enough that a healthy build refreshes
# many times within the staleness window; staleness is generous enough that
# a temporarily-stuck mkdir or `kill -0` glitch on the holder is forgiven.
GLOBAL_SEMAPHORE_HEARTBEAT_INTERVAL_SECONDS=15
GLOBAL_SEMAPHORE_HEARTBEAT_STALENESS_SECONDS=120

export HARNESS_MONITOR_APP_ROOT="$ROOT"

args=("$@")
normalized_path_mappings=()
derive_data_path=""
lock_path=""
lock_owned=0
global_slot_path=""
global_slot_owned=0
global_heartbeat_pid=""

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
  local pid command started heartbeat_text="no heartbeat"
  pid="$(sed -n 's/^pid=//p' "$owner_file" | head -n 1)"
  started="$(sed -n 's/^started_at=//p' "$owner_file" | head -n 1)"
  command="$(ps -p "$pid" -o command= 2>/dev/null | sed 's/^[[:space:]]*//')"
  local heartbeat_file
  heartbeat_file="$(dirname "$owner_file")/heartbeat"
  if [[ -e "$heartbeat_file" ]]; then
    # /usr/bin/stat to force BSD stat. Plain `stat` may resolve to GNU stat
    # via coreutils on PATH; BSD's `-f FMT` and GNU's `-f` (--file-system)
    # mean different things, so the bare name is not portable here.
    local mtime now_epoch age
    mtime="$(/usr/bin/stat -f '%m' "$heartbeat_file" 2>/dev/null)"
    now_epoch="$(/bin/date +%s)"
    if [[ "$mtime" =~ ^[0-9]+$ ]]; then
      age=$((now_epoch - mtime))
      heartbeat_text="${age}s ago"
    fi
  fi
  printf 'pid=%s started_at=%s heartbeat=%s command=%s\n' \
    "${pid:-?}" "${started:-?}" "$heartbeat_text" "${command:-?}"
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

# Counting semaphore that all build lanes share. Default cap is one concurrent
# `xcodebuild` invocation across the whole machine: a 14-core M3 Max saturates
# at ~10 cores during a single Monitor build, so two parallel agents already
# put the OS scheduler past 100%. Measured today with four lanes running at
# once: load average 84, RAM full, swap thrashing, individual builds 3-4x
# slower than wall time would predict. The per-lane lock at
# `$derive_data_path/.harness-monitor-xcodebuild.lock` is orthogonal -- it
# still protects each lane from internal concurrent invocations. This
# semaphore protects the host from cross-lane oversubscription.
#
# Liveness: the slot owner is "alive" iff (a) its PID still exists AND
# (b) its heartbeat file mtime is within
# GLOBAL_SEMAPHORE_HEARTBEAT_STALENESS_SECONDS of now (or the slot is fresh
# enough that no heartbeat is expected yet). The PID check alone isn't enough
# -- a wrapper that has gone unresponsive (stuck in xcodebuild waiting for
# some other resource) still has a live PID but isn't making progress; a
# stale heartbeat is the explicit signal that "another agent thinking they
# can take this slot" is correct.
# Returns 0 if any descendant PID listed in the slot's descendant_pids file
# is still alive (excluding the heartbeat process itself, which is parented
# at the wrapper and would otherwise count). Used as a fallback liveness
# signal when the heartbeat file has gone stale: if xcodebuild or any of
# its formatter-pipeline siblings is still running under the wrapper, the
# slot is healthy even though the heartbeat hasn't touched recently.
global_slot_descendant_alive() {
  local slot="$1"
  local descendants_file="$slot/descendant_pids"
  [[ -f "$descendants_file" ]] || return 1
  local child
  while IFS= read -r child; do
    [[ "$child" =~ ^[0-9]+$ ]] || continue
    if kill -0 "$child" 2>/dev/null; then
      return 0
    fi
  done < "$descendants_file"
  return 1
}

global_slot_is_alive() {
  # All `stat` / `date` invocations use absolute paths so GNU coreutils on
  # PATH does not shadow the BSD-flag semantics we rely on (-f FMT for stat,
  # -j -f for date).
  local slot="$1"
  local owner_file="$slot/owner.env"
  local heartbeat_file="$slot/heartbeat"
  [[ -f "$owner_file" ]] || return 1
  local pid
  pid="$(sed -n 's/^pid=//p' "$owner_file" | head -n 1)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  local now_epoch
  now_epoch="$(/bin/date +%s)"
  if [[ -e "$heartbeat_file" ]]; then
    local mtime
    mtime="$(/usr/bin/stat -f '%m' "$heartbeat_file" 2>/dev/null)" || return 1
    [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
    if (( now_epoch - mtime > GLOBAL_SEMAPHORE_HEARTBEAT_STALENESS_SECONDS )); then
      # Heartbeat stale, but the wrapper PID is still alive. Cross-check
      # the descendant_pids file: if xcodebuild (or any other formatter-
      # pipeline child) is still running under the wrapper, the wrapper
      # is doing real work and the stale heartbeat means the heartbeat
      # subprocess died or its touch() is failing -- not that the slot
      # is abandoned. Only when both signals agree on "dead" do we
      # reclaim.
      if global_slot_descendant_alive "$slot"; then
        return 0
      fi
      return 1
    fi
    return 0
  fi
  # No heartbeat file yet -- give the holder one staleness window to write
  # the first heartbeat before declaring it stale (covers the brief gap
  # between mkdir success and the first `touch heartbeat`).
  local started_at started_epoch
  started_at="$(sed -n 's/^started_at=//p' "$owner_file" | head -n 1)"
  started_epoch="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$started_at" +%s 2>/dev/null)"
  [[ "$started_epoch" =~ ^[0-9]+$ ]] || return 0
  if (( now_epoch - started_epoch > GLOBAL_SEMAPHORE_HEARTBEAT_STALENESS_SECONDS )); then
    return 1
  fi
  return 0
}

spawn_global_xcodebuild_heartbeat() {
  local slot_path="$1"
  local heartbeat_file="$slot_path/heartbeat"
  local descendants_file="$slot_path/descendant_pids"
  local wrapper_pid="$$"
  /usr/bin/touch "$heartbeat_file"
  # Heartbeat must survive transient touch() failures (a brief FS hiccup, a
  # backup process holding the parent dir for a moment, etc.). If it exits
  # on the first failed touch, mtime goes stale within
  # GLOBAL_SEMAPHORE_HEARTBEAT_STALENESS_SECONDS and another wrapper
  # reclaims the slot while *this* wrapper still has xcodebuild running --
  # the exact race we fixed here. Only the trap'd TERM/INT/HUP (set by
  # cleanup_descendants_and_lock) ends the heartbeat. Touch failures
  # swallow and retry on the next interval.
  #
  # The descendants file is a second liveness signal: every interval we
  # rewrite the wrapper's direct child PIDs (the formatter pipeline +
  # xcodebuild). If the heartbeat *file* later goes stale despite this
  # process still running (rare -- requires touch() to keep failing),
  # global_slot_is_alive can fall back to "any descendant PID listed here
  # is alive" before declaring the slot dead and reclaiming it. Together
  # the two signals close the original "heartbeat dies, xcodebuild
  # continues" race regardless of which side fails.
  (
    trap 'exit 0' TERM INT HUP
    while :; do
      sleep "$GLOBAL_SEMAPHORE_HEARTBEAT_INTERVAL_SECONDS"
      /usr/bin/touch "$heartbeat_file" 2>/dev/null || true
      # Direct children of the wrapper. Excludes the heartbeat itself
      # because pgrep -P sees only the wrapper's children, not its own
      # forked grandchildren; this subshell is parented at the wrapper
      # so it does show up. The reaper de-dupes against its own pid.
      /usr/bin/pgrep -P "$wrapper_pid" 2>/dev/null > "$descendants_file.tmp" || true
      /bin/mv "$descendants_file.tmp" "$descendants_file" 2>/dev/null || true
    done
  ) &
  global_heartbeat_pid=$!
  disown "$global_heartbeat_pid" 2>/dev/null || true
}

stop_global_xcodebuild_heartbeat() {
  if [[ -n "$global_heartbeat_pid" ]]; then
    kill -TERM "$global_heartbeat_pid" 2>/dev/null || true
    global_heartbeat_pid=""
  fi
}

acquire_global_xcodebuild_semaphore() {
  if (( GLOBAL_CONCURRENCY <= 0 )); then
    return 0
  fi
  mkdir -p "$GLOBAL_SEMAPHORE_DIR"
  local deadline=$((SECONDS + LOCK_WAIT_TIMEOUT_SECONDS))
  local slot existing
  while :; do
    for existing in "$GLOBAL_SEMAPHORE_DIR"/slot-*; do
      [[ -d "$existing" ]] || continue
      if global_slot_is_alive "$existing"; then
        continue
      fi
      rm -rf "$existing"
    done
    local i
    for ((i = 1; i <= GLOBAL_CONCURRENCY; i += 1)); do
      slot="$GLOBAL_SEMAPHORE_DIR/slot-$i"
      if mkdir "$slot" 2>/dev/null; then
        {
          printf 'pid=%s\n' "$$"
          printf 'started_at=%s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
          printf 'derived_data_path=%s\n' "$derive_data_path"
          printf 'caller_pwd=%s\n' "$CALLER_PWD"
        } > "$slot/owner.env"
        global_slot_path="$slot"
        global_slot_owned=1
        spawn_global_xcodebuild_heartbeat "$slot"
        return 0
      fi
    done
    if (( LOCK_WAIT_TIMEOUT_SECONDS == 0 || SECONDS < deadline )); then
      sleep 1
      continue
    fi
    printf 'error: All %d Harness Monitor xcodebuild concurrency slots are busy.\n' "$GLOBAL_CONCURRENCY" >&2
    for existing in "$GLOBAL_SEMAPHORE_DIR"/slot-*; do
      [[ -d "$existing" ]] || continue
      printf '  busy: %s -> %s\n' "$(basename "$existing")" "$(describe_lock_owner "$existing/owner.env")" >&2
    done
    printf 'wait via XCODEBUILD_LOCK_WAIT_TIMEOUT_SECONDS=0 (the slot will be released when the current build finishes). The cap is hardcoded at %d in Scripts/monitor-xcodebuild.sh and CANNOT be raised by env var; an agent that wants more concurrency would have to land a script change, which is visible in git.\n' "$GLOBAL_CONCURRENCY" >&2
    return 73
  done
}

release_global_xcodebuild_semaphore() {
  if (( global_slot_owned == 1 )) && [[ -n "$global_slot_path" ]]; then
    rm -rf "$global_slot_path"
  fi
}

cleanup_descendants_and_lock() {
  local status="${1:-$?}"
  trap - EXIT INT TERM HUP
  stop_global_xcodebuild_heartbeat
  terminate_descendant_processes "$$"
  release_xcodebuild_lock
  release_global_xcodebuild_semaphore
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

build_setting_arg_present() {
  local key="$1"
  local arg
  for arg in "${args[@]}"; do
    if [[ "$arg" == "$key="* ]]; then
      return 0
    fi
  done
  return 1
}

xcodebuild_configuration() {
  local index arg
  for ((index = 0; index < ${#args[@]}; index += 1)); do
    arg="${args[index]}"
    if [[ "$arg" == "-configuration" ]] && (( index + 1 < ${#args[@]} )); then
      printf '%s\n' "${args[index + 1]}"
      return 0
    fi
    if [[ "$arg" == -configuration=* ]]; then
      printf '%s\n' "${arg#*=}"
      return 0
    fi
  done
  printf 'Debug\n'
}

inject_local_script_sandbox_override() {
  local configuration
  if [[ "${HARNESS_MONITOR_KEEP_USER_SCRIPT_SANDBOXING:-0}" == "1" ]]; then
    return 0
  fi
  if build_setting_arg_present "ENABLE_USER_SCRIPT_SANDBOXING"; then
    return 0
  fi
  configuration="$(xcodebuild_configuration)"
  case "$configuration" in
    Debug|Preview)
      args+=("ENABLE_USER_SCRIPT_SANDBOXING=NO")
      ;;
  esac
}

# Point COMPILATION_CACHE_CAS_PATH at a fixed location shared across every
# build lane. Default is `$(DERIVED_DATA_DIR)/CompilationCache.noindex/builtin`,
# which lives inside the per-lane DerivedData under
# `xcode-derived-lanes/<lane>/`. A fresh lane name therefore starts with an
# empty CAS and every cacheable Swift task is a miss until that lane warms up
# (observed: 0 hits / 377 cacheable tasks on the first build into a new lane).
# Pointing all lanes at the user's standard `~/Library/Developer/Xcode/
# DerivedData/CompilationCache.noindex/builtin` lets a new lane reuse compile
# artifacts the Xcode UI and prior lanes have already cached.
#
# CAS storage is content-addressed -- concurrent writers from parallel lanes
# only collide on identical keys, where they would have stored the same blob
# anyway, so sharing is safe. Opt out with HARNESS_MONITOR_SHARED_COMPILATION_CAS=0
# (e.g. when bisecting a CAS-corruption regression).
inject_shared_compilation_cache_path() {
  if [[ "${HARNESS_MONITOR_SHARED_COMPILATION_CAS:-1}" != "1" ]]; then
    return 0
  fi
  if build_setting_arg_present "COMPILATION_CACHE_CAS_PATH"; then
    return 0
  fi
  local shared_cas_path="${HOME}/Library/Developer/Xcode/DerivedData/CompilationCache.noindex/builtin"
  mkdir -p "$shared_cas_path"
  args+=("COMPILATION_CACHE_CAS_PATH=$shared_cas_path")
}

# Isolate the daemon cargo target dir per build lane so parallel agents do
# not invalidate each other's (or the user's) cargo fingerprint cache.
#
# Cargo's fingerprint is keyed by (rustc_version, args, Cargo.lock entries,
# source files). With the default cache at `$COMMON_REPO_ROOT/.cache/harness-
# monitor-xcode-daemon/`, every worktree pointing its build at that single
# directory writes a new fingerprint dir whenever its Cargo.lock content or
# feature resolution differs from the previous build. Observed today: 12
# distinct fingerprint dirs for the `harness` daemon binary itself, 24 for
# `rustls`, 16 for `getrandom`, 1,732 total across all crates -- because
# different worktrees have different Cargo.lock SHAs.
#
# Fix: a named build lane (HARNESS_MONITOR_BUILD_LANE=...) gets its own
# daemon target dir under the lane's DerivedData. The unnamed/default lane
# (user's Xcode Cmd+R) keeps the shared `.cache/harness-monitor-xcode-daemon`
# untouched. Agents now no longer thrash the user's daemon cache.
#
# Skip if the caller has already exported HARNESS_MONITOR_DAEMON_CARGO_TARGET_DIR
# or CARGO_TARGET_DIR -- those are explicit overrides we should not stomp.
inject_lane_daemon_cargo_target_dir() {
  if [[ "${HARNESS_MONITOR_PER_LANE_DAEMON_CACHE:-1}" != "1" ]]; then
    return 0
  fi
  if [[ -n "${HARNESS_MONITOR_DAEMON_CARGO_TARGET_DIR:-}" ]]; then
    return 0
  fi
  if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
    return 0
  fi
  # Only redirect when this is a *named* lane. The default lane lives at
  # `xcode-derived/` (not inside `xcode-derived-lanes/`), which is exactly
  # the case where we want to keep using the shared `.cache/...` cache.
  case "$derive_data_path" in
    *"/xcode-derived-lanes/"*)
      export HARNESS_MONITOR_DAEMON_CARGO_TARGET_DIR="$derive_data_path/cargo-target"
      ;;
  esac
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
inject_local_script_sandbox_override
inject_shared_compilation_cache_path
inject_lane_daemon_cargo_target_dir
export XCODEBUILD_DERIVED_DATA_PATH="$derive_data_path"
ensure_non_indexable_directory "$derive_data_path"

run_stale_preflight
trap 'cleanup_descendants_and_lock $?' EXIT
trap 'cleanup_descendants_and_lock 130' INT
if [[ "${HARNESS_MONITOR_BUILD_PROTECT_INFLIGHT:-1}" == "1" ]]; then
  # POSIX preserves the ignore disposition across exec(), so xcodebuild (and
  # tuist/xcbeautify in the formatter pipeline) inherit the ignore from us.
  # Only SIGINT (user Ctrl-C) and SIGKILL can cancel a running build.
  # Set HARNESS_MONITOR_BUILD_PROTECT_INFLIGHT=0 to opt out.
  trap '' TERM HUP
else
  trap 'cleanup_descendants_and_lock 143' TERM
  trap 'cleanup_descendants_and_lock 129' HUP
fi

acquire_global_xcodebuild_semaphore
acquire_xcodebuild_lock
run_xcodebuild
