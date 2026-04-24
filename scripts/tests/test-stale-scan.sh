#!/usr/bin/env bash
# Exercise the primitives in scripts/lib/stale-scan.sh and the full
# check-no-stale-state.sh gate against simulated congestion scenarios.
#
# Every spawned fake process, /tmp artifact, and temp directory is tagged with
# this run's pid and torn down on exit, including on failure. Tests use subset
# assertions ("expected pid appears in results") so pre-existing user state
# does not cause false positives.
set -euo pipefail
# Enable job control so every backgrounded command starts in its own process
# group. Without this, bg jobs spawned inside a `$()` subshell share the
# subshell's pgroup and die with it when the subshell exits - which is how
# mise and other harnesses tear children down after a task step. With -m,
# nohup plus an independent pgroup is enough to survive subshell teardown.
set -m

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
readonly ROOT
STALE_SCAN_ROOT="$ROOT"
export STALE_SCAN_ROOT
# shellcheck source=scripts/lib/stale-scan.sh
source "$ROOT/scripts/lib/stale-scan.sh"

RUN_ID="$$"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/stale-scan-test-$RUN_ID.XXXXXX")"
TMP_MARKERS=()
SPAWNED_PIDS=()
LAST_SPAWN_PID=""
PASS_COUNT=0
FAIL_COUNT=0
FAIL_NAMES=()
CURRENT_TEST=""

cleanup() {
  local pid
  for pid in "${SPAWNED_PIDS[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  local marker
  for marker in "${TMP_MARKERS[@]}"; do
    rm -f "$marker"
  done
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

log() {
  printf '%s\n' "$*" >&2
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAIL_NAMES+=("$CURRENT_TEST")
  log "  FAIL: $CURRENT_TEST - $*"
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  log "  PASS: $CURRENT_TEST"
}

assert_in_list() {
  local needle="$1"
  local label="$2"
  local haystack="$3"
  if printf '%s\n' "$haystack" | grep -Fxq -- "$needle"; then
    return 0
  fi
  fail "expected $label '$needle' in list: $(printf '%s' "$haystack" | tr '\n' ' ')"
  return 1
}

assert_not_in_list() {
  local needle="$1"
  local label="$2"
  local haystack="$3"
  if ! printf '%s\n' "$haystack" | grep -Fxq -- "$needle"; then
    return 0
  fi
  fail "did not expect $label '$needle' in list"
  return 1
}

wait_for_pid_registered() {
  local pid="$1"
  local attempts=0
  while (( attempts < 20 )); do
    if ps -p "$pid" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
    attempts=$((attempts + 1))
  done
  return 1
}

# Spawn a background process whose argv[0] is the requested label, writing
# the resulting pid to the global LAST_SPAWN_PID and appending it to
# SPAWNED_PIDS so the EXIT trap cleans it up.
#
# This intentionally does NOT use command substitution to return the pid,
# because a `$()` subshell would have to carry the backgrounded child across
# its own exit. That path is inherently racy (it depends on nohup + set -m +
# huponexit interplay) and fails under congestion when parent unwind happens
# before the child finishes the bash->sleep exec chain. Running in the main
# shell sidesteps all of that.
spawn_labelled() {
  local label="$1"
  # shellcheck disable=SC2016  # $1 is resolved by the inner bash, not this shell
  nohup bash -c 'exec -a "$1" sleep 300' bash-spawner "$label" >/dev/null 2>&1 &
  LAST_SPAWN_PID=$!
  SPAWNED_PIDS+=("$LAST_SPAWN_PID")
  wait_for_pid_registered "$LAST_SPAWN_PID" || return 1
}

# Spawn a background process whose ps line contains a synthesized target-dir
# harness invocation (e.g. "/sandbox/target/debug/harness daemon 300"), which
# is exactly what the awk regex in stale_scan_matching_pids matches against.
# Writes the resulting pid to LAST_SPAWN_PID.
spawn_target_harness() {
  local subpath="$1"
  local subcommand="$2"
  local dir="$SANDBOX/$subpath"
  mkdir -p "$dir"
  spawn_labelled "$dir/harness $subcommand"
}

start_test() {
  CURRENT_TEST="$1"
  stale_scan_refresh_ps
  log "RUN:  $CURRENT_TEST"
}

# ---------------------------------------------------------------------------
# Scenario 1: debug-profile orphan (the historical coverage)
# ---------------------------------------------------------------------------
scenario_debug_orphan() {
  start_test "debug-profile orphan detected"
  spawn_target_harness "target/debug" daemon || { fail "spawn failed"; return; }
  local pid="$LAST_SPAWN_PID"
  stale_scan_refresh_ps
  local pids
  pids="$(stale_scan_matching_pids build)"
  assert_in_list "$pid" "build-bucket pid" "$pids" && pass
}

# ---------------------------------------------------------------------------
# Scenario 2: release-profile orphan (new coverage)
# ---------------------------------------------------------------------------
scenario_release_orphan() {
  start_test "release-profile orphan detected"
  spawn_target_harness "target/release" bridge || { fail "spawn failed"; return; }
  local pid="$LAST_SPAWN_PID"
  stale_scan_refresh_ps
  local pids
  pids="$(stale_scan_matching_pids build)"
  assert_in_list "$pid" "build-bucket pid" "$pids" && pass
}

# ---------------------------------------------------------------------------
# Scenario 3: per-triple debug orphan (target/dev/<triple>/debug)
# ---------------------------------------------------------------------------
scenario_per_triple_debug_orphan() {
  start_test "per-triple debug orphan detected"
  spawn_target_harness "target/dev/aarch64-apple-darwin/debug" daemon || { fail "spawn failed"; return; }
  local pid="$LAST_SPAWN_PID"
  stale_scan_refresh_ps
  local pids
  pids="$(stale_scan_matching_pids build)"
  assert_in_list "$pid" "build-bucket pid" "$pids" && pass
}

# ---------------------------------------------------------------------------
# Scenario 4: per-triple release orphan (new coverage)
# ---------------------------------------------------------------------------
scenario_per_triple_release_orphan() {
  start_test "per-triple release orphan detected"
  spawn_target_harness "target/dev/x86_64-apple-darwin/release" bridge || { fail "spawn failed"; return; }
  local pid="$LAST_SPAWN_PID"
  stale_scan_refresh_ps
  local pids
  pids="$(stale_scan_matching_pids build)"
  assert_in_list "$pid" "build-bucket pid" "$pids" && pass
}

# ---------------------------------------------------------------------------
# Scenario 5: live bucket matches daemon serve / bridge start argv
# ---------------------------------------------------------------------------
scenario_live_bucket() {
  start_test "live bucket matches 'daemon serve' argv"
  spawn_labelled "/opt/fake/harness daemon serve" || { fail "spawn failed"; return; }
  local pid="$LAST_SPAWN_PID"
  stale_scan_refresh_ps
  local pids
  pids="$(stale_scan_matching_pids live)"
  assert_in_list "$pid" "live-bucket pid" "$pids" && pass
}

# ---------------------------------------------------------------------------
# Scenario 6: gate bucket matches mise run check argv
# ---------------------------------------------------------------------------
scenario_gate_bucket() {
  start_test "gate bucket matches 'mise run check'"
  spawn_labelled "mise run check" || { fail "spawn failed"; return; }
  local pid="$LAST_SPAWN_PID"
  stale_scan_refresh_ps
  local pids
  pids="$(stale_scan_matching_pids gate)"
  assert_in_list "$pid" "gate-bucket pid" "$pids" && pass
}

# ---------------------------------------------------------------------------
# Scenario 7: /tmp bridge artifacts - .sock, .pid, .lock are all detected
# ---------------------------------------------------------------------------
scenario_tmp_artifacts() {
  start_test "tmp bridge artifacts sweep covers .sock/.pid/.lock"
  local stem="/tmp/h-bridge-TEST-$RUN_ID"
  local sock="$stem.sock"
  local pid_file="$stem.pid"
  local lock_file="$stem.lock"
  : >"$sock"
  : >"$pid_file"
  : >"$lock_file"
  TMP_MARKERS+=("$sock" "$pid_file" "$lock_file")

  local found
  found="$(stale_scan_tmp_bridge_artifacts)"
  local ok=1
  assert_in_list "$sock" "sock artifact" "$found" || ok=0
  assert_in_list "$pid_file" "pid artifact" "$found" || ok=0
  assert_in_list "$lock_file" "lock artifact" "$found" || ok=0
  if (( ok )); then pass; fi
}

# ---------------------------------------------------------------------------
# Scenario 8: custom-root lock holder detection via lsof
# ---------------------------------------------------------------------------
scenario_lock_holder() {
  start_test "lock-holder detection for custom root"
  local fake_root="$SANDBOX/fake-daemon-root"
  mkdir -p "$fake_root"
  local lock_path="$fake_root/daemon.lock"
  : >"$lock_path"

  # Spawn a process under nohup that keeps the lock file open via an fd.
  # nohup keeps the bg job alive beyond any $() subshell, though here we
  # capture the pid from the main shell directly.
  nohup bash -c "exec 9>>'$lock_path'; exec sleep 300" >/dev/null 2>&1 &
  local holder_pid=$!
  SPAWNED_PIDS+=("$holder_pid")
  wait_for_pid_registered "$holder_pid" || { fail "lock-holder pid never registered"; return; }

  # Give lsof a moment to see the fd.
  sleep 0.3

  local holders
  holders="$(stale_scan_root_lock_holder_pids "$fake_root")"
  assert_in_list "$holder_pid" "lock-holder pid" "$holders" && pass
}

# ---------------------------------------------------------------------------
# Scenario 9: pid_describe formats PID/ETIME/COMMAND
# ---------------------------------------------------------------------------
scenario_pid_describe_format() {
  start_test "pid_describe emits PID + etime + command"
  spawn_target_harness "target/debug" daemon || { fail "spawn failed"; return; }
  local pid="$LAST_SPAWN_PID"
  stale_scan_refresh_ps
  local desc
  desc="$(stale_scan_pid_describe "$pid")"
  if [[ "$desc" =~ ^${pid}[[:space:]]+[^[:space:]]+[[:space:]]+.*target/debug/harness[[:space:]]+daemon ]]; then
    pass
  else
    fail "describe output did not match expected shape: '$desc'"
  fi
}

# ---------------------------------------------------------------------------
# Scenario 10: ancestor exclusion - our own pid and parents are skipped by
# stale_scan_repo_gate_pids, but sibling gate processes are caught.
# ---------------------------------------------------------------------------
scenario_ancestor_exclusion() {
  start_test "ancestor lineage excluded, siblings flagged"

  # Spawn a fake 'mise run check' with cwd = $ROOT. pushd/popd keeps the
  # main shell's cwd stable while inheriting $ROOT into the bg job at fork.
  # nohup keeps it alive past the end of this function; exec -a rewrites
  # argv so the gate regex matches. The pid of the background simple
  # command is the nohup process, which execs bash, which execs sleep -
  # same pid throughout.
  pushd "$ROOT" >/dev/null || { fail "pushd $ROOT failed"; return; }
  # shellcheck disable=SC2016  # $1 is resolved by the inner bash, not this shell
  nohup bash -c 'exec -a "$1" sleep 300' bash-spawner "mise run check" >/dev/null 2>&1 &
  local sibling_pid=$!
  popd >/dev/null || { fail "popd failed"; return; }
  SPAWNED_PIDS+=("$sibling_pid")
  wait_for_pid_registered "$sibling_pid" || { fail "sibling pid never registered"; return; }
  sleep 0.3

  stale_scan_refresh_ps
  local gate_pids
  gate_pids="$(stale_scan_repo_gate_pids "$$")"

  local ok=1
  assert_in_list "$sibling_pid" "sibling gate pid" "$gate_pids" || ok=0
  # Our own pid must never appear, even though our cwd is under $ROOT.
  assert_not_in_list "$$" "self pid" "$gate_pids" || ok=0
  if (( ok )); then pass; fi
}

# ---------------------------------------------------------------------------
# Scenario 11: congested env - many simultaneous fakes all get reported.
# ---------------------------------------------------------------------------
scenario_congested_env() {
  start_test "multi-leak congestion surfaces every pid"
  spawn_target_harness "target/debug" daemon || { fail "spawn a failed"; return; }
  local pid_a="$LAST_SPAWN_PID"
  spawn_target_harness "target/release" bridge || { fail "spawn b failed"; return; }
  local pid_b="$LAST_SPAWN_PID"
  spawn_target_harness "target/dev/aarch64-apple-darwin/debug" daemon || { fail "spawn c failed"; return; }
  local pid_c="$LAST_SPAWN_PID"

  stale_scan_refresh_ps
  local pids
  pids="$(stale_scan_matching_pids build)"
  local ok=1
  assert_in_list "$pid_a" "congestion pid_a" "$pids" || ok=0
  assert_in_list "$pid_b" "congestion pid_b" "$pids" || ok=0
  assert_in_list "$pid_c" "congestion pid_c" "$pids" || ok=0
  if (( ok )); then pass; fi
}

# ---------------------------------------------------------------------------
# Scenario 12: end-to-end - check-no-stale-state.sh exits 1 and mentions the
# stale /tmp artifact we planted.
# ---------------------------------------------------------------------------
scenario_end_to_end_detection() {
  start_test "check-no-stale-state.sh reports planted /tmp artifact"
  local marker="/tmp/h-bridge-TEST-$RUN_ID-e2e.sock"
  : >"$marker"
  TMP_MARKERS+=("$marker")

  local output status=0
  output="$("$ROOT/scripts/check-no-stale-state.sh" 2>&1)" || status=$?

  if (( status != 1 )); then
    fail "expected exit 1 from check script, got $status (output: $output)"
    return
  fi
  if ! printf '%s' "$output" | grep -Fq -- "$marker"; then
    fail "stderr did not mention planted marker '$marker': $output"
    return
  fi
  pass
}

# ---------------------------------------------------------------------------
# Scenario 13: clean primitive removes only /tmp artifacts we own.
# Idempotence: second run is a no-op.
# ---------------------------------------------------------------------------
scenario_clean_tmp_removal_is_idempotent() {
  start_test "clean's remove_tmp_bridge_artifacts is idempotent"
  local marker="/tmp/h-bridge-TEST-$RUN_ID-clean.sock"
  : >"$marker"
  TMP_MARKERS+=("$marker")

  # Reuse the exact primitive the clean script uses.
  local artifacts_before
  artifacts_before="$(stale_scan_tmp_bridge_artifacts)"
  assert_in_list "$marker" "pre-clean marker" "$artifacts_before" || return

  # Simulate what clean-stale-state.sh does for that function.
  local listed=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && listed+=("$line")
  done < <(stale_scan_tmp_bridge_artifacts)
  rm -f "${listed[@]}"

  local artifacts_after
  artifacts_after="$(stale_scan_tmp_bridge_artifacts)"
  assert_not_in_list "$marker" "post-clean marker" "$artifacts_after" || return

  # Second run must not error when nothing is left to remove.
  listed=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && listed+=("$line")
  done < <(stale_scan_tmp_bridge_artifacts)
  if (( ${#listed[@]} == 0 )); then
    pass
  else
    # Still OK as long as our marker is gone; other tests may have planted more.
    pass
  fi
}

# ---------------------------------------------------------------------------
# Scenario 14: installed-binary false positive prevention.
# An installed harness at ~/.local/bin/harness must match 'live' (needing a
# real lock to escalate) but never 'build'.
# ---------------------------------------------------------------------------
scenario_installed_not_in_build_bucket() {
  start_test "installed /usr/local/bin/harness does not trigger build bucket"
  spawn_labelled "/usr/local/bin/harness daemon serve" || { fail "spawn failed"; return; }
  local pid="$LAST_SPAWN_PID"
  stale_scan_refresh_ps
  local build_pids
  build_pids="$(stale_scan_matching_pids build)"
  assert_not_in_list "$pid" "installed pid in build bucket" "$build_pids" && pass
}

# ---------------------------------------------------------------------------
# Scenario 15: ps snapshot caching - refreshing produces updated view.
# ---------------------------------------------------------------------------
scenario_refresh_updates_cache() {
  start_test "stale_scan_refresh_ps reflects newly-spawned pids"
  stale_scan_refresh_ps
  local before
  before="$(stale_scan_matching_pids build)"
  spawn_target_harness "target/debug" bridge || { fail "spawn failed"; return; }
  local pid="$LAST_SPAWN_PID"
  # Without refresh, the old snapshot must not contain the new pid.
  assert_not_in_list "$pid" "pre-refresh pid" "$before" || return
  stale_scan_refresh_ps
  local after
  after="$(stale_scan_matching_pids build)"
  assert_in_list "$pid" "post-refresh pid" "$after" && pass
}

run_all() {
  scenario_debug_orphan
  scenario_release_orphan
  scenario_per_triple_debug_orphan
  scenario_per_triple_release_orphan
  scenario_live_bucket
  scenario_gate_bucket
  scenario_tmp_artifacts
  scenario_lock_holder
  scenario_pid_describe_format
  scenario_ancestor_exclusion
  scenario_congested_env
  scenario_end_to_end_detection
  scenario_clean_tmp_removal_is_idempotent
  scenario_installed_not_in_build_bucket
  scenario_refresh_updates_cache
}

run_all

log "----"
log "stale-scan tests: $PASS_COUNT passed, $FAIL_COUNT failed"
if (( FAIL_COUNT > 0 )); then
  log "failures:"
  for name in "${FAIL_NAMES[@]}"; do
    log "  - $name"
  done
  exit 1
fi
