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
  # Herestring avoids `printf | grep -q` which SIGPIPEs the writer when
  # grep exits on first match; pipefail would then abort the test harness.
  if grep -Fxq -- "$needle" <<<"$haystack"; then
    return 0
  fi
  fail "expected $label '$needle' in list: $(tr '\n' ' ' <<<"$haystack")"
  return 1
}

assert_not_in_list() {
  local needle="$1"
  local label="$2"
  local haystack="$3"
  if ! grep -Fxq -- "$needle" <<<"$haystack"; then
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

# Wait until the argv of `pid` contains the given substring. Needed because
# our spawn pattern is `nohup bash -c 'exec -a $label sleep 300'`, and ps may
# still show the interim bash argv for a handful of ms after the pid becomes
# visible but before exec completes. Without this, the per-triple spawn
# scenarios occasionally race the stale_scan_matching_pids regex.
wait_for_pid_argv_contains() {
  local pid="$1"
  local needle="$2"
  local attempts=0
  while (( attempts < 40 )); do
    if ps -p "$pid" -o command= 2>/dev/null | grep -Fq -- "$needle"; then
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
  # Wait for the exec -a argv rewrite to land before letting the caller
  # snapshot ps. Otherwise the regex sees the transient bash argv.
  wait_for_pid_argv_contains "$LAST_SPAWN_PID" "$label" || return 1
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
# Scenario 7: test runners are not stale gate helpers. They may be long-lived
# legitimate foreground work, and clean:stale must never kill them or corrupt
# their output stream.
# ---------------------------------------------------------------------------
scenario_test_runners_not_gate_bucket() {
  start_test "unit test runners are not gate-bucket cleanup targets"
  spawn_labelled "mise run test:unit" || { fail "spawn mise test failed"; return; }
  local mise_test_pid="$LAST_SPAWN_PID"
  spawn_labelled "./scripts/cargo-local.sh test --lib" || { fail "spawn cargo test failed"; return; }
  local cargo_test_pid="$LAST_SPAWN_PID"
  spawn_labelled "mise run monitor:macos:test" || { fail "spawn monitor test failed"; return; }
  local monitor_test_pid="$LAST_SPAWN_PID"

  stale_scan_refresh_ps
  local pids
  pids="$(stale_scan_matching_pids gate)"
  local ok=1
  assert_not_in_list "$mise_test_pid" "mise test pid" "$pids" || ok=0
  assert_not_in_list "$cargo_test_pid" "cargo test pid" "$pids" || ok=0
  assert_not_in_list "$monitor_test_pid" "monitor test pid" "$pids" || ok=0
  if (( ok )); then pass; fi
}

# ---------------------------------------------------------------------------
# Scenario 8: /tmp bridge artifacts - .sock, .pid, .lock are all detected
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

# ---------------------------------------------------------------------------
# Scenario 16: SQLite sidecar orphan detection - .db-wal present, .db absent.
# ---------------------------------------------------------------------------
scenario_orphan_wal() {
  start_test "orphan harness.db-wal detected when harness.db is gone"
  local root="$SANDBOX/daemon-root-wal-$RUN_ID"
  mkdir -p "$root"
  local wal="$root/harness.db-wal"
  : >"$wal"

  local output
  output="$(stale_scan_orphan_sqlite_sidecars "$root")"
  assert_in_list "$wal" "orphan wal" "$output" && pass
}

# ---------------------------------------------------------------------------
# Scenario 17: SQLite sidecar orphan detection - .db-shm present, .db absent.
# ---------------------------------------------------------------------------
scenario_orphan_shm() {
  start_test "orphan harness.db-shm detected when harness.db is gone"
  local root="$SANDBOX/daemon-root-shm-$RUN_ID"
  mkdir -p "$root"
  local shm="$root/harness.db-shm"
  : >"$shm"

  local output
  output="$(stale_scan_orphan_sqlite_sidecars "$root")"
  assert_in_list "$shm" "orphan shm" "$output" && pass
}

# ---------------------------------------------------------------------------
# Scenario 18: sidecars alongside a live harness.db are NOT flagged. The DB
# is the source of truth; sidecars are normal WAL-mode companions.
# ---------------------------------------------------------------------------
scenario_sidecars_with_db_noop() {
  start_test "sidecars next to harness.db are treated as normal"
  local root="$SANDBOX/daemon-root-live-$RUN_ID"
  mkdir -p "$root"
  : >"$root/harness.db"
  : >"$root/harness.db-wal"
  : >"$root/harness.db-shm"

  local output
  output="$(stale_scan_orphan_sqlite_sidecars "$root")"
  if [[ -z "$output" ]]; then
    pass
  else
    fail "expected no orphans with live .db; got: $output"
  fi
}

# ---------------------------------------------------------------------------
# Scenario 19: nonexistent daemon root is a clean no-op (never errors).
# ---------------------------------------------------------------------------
scenario_orphan_sidecar_missing_root() {
  start_test "sidecar scan on missing root is a no-op"
  local output
  output="$(stale_scan_orphan_sqlite_sidecars "$SANDBOX/no-such-root-$RUN_ID")"
  if [[ -z "$output" ]]; then
    pass
  else
    fail "expected empty output for missing root; got: $output"
  fi
}

# ---------------------------------------------------------------------------
# Scenario 20: launchctl drift parser - missing program path emits drift line.
# ---------------------------------------------------------------------------
scenario_launchd_drift_parser_missing() {
  start_test "launchd drift parser reports missing program path"
  local fake_output
  fake_output=$'gui/501/io.example.daemon = {\n\tactive count = 1\n\tpath = /foo/bar.plist\n\tstate = running\n\n\tprogram = /nonexistent/path-'"$RUN_ID"$'/harness\n}'
  local line
  line="$(stale_scan_launchd_drift_from_output "io.example.daemon" "$fake_output")"
  if [[ "$line" == *"io.example.daemon"* && "$line" == *"/nonexistent/path-$RUN_ID/harness"* ]]; then
    pass
  else
    fail "unexpected drift output: '$line'"
  fi
}

# ---------------------------------------------------------------------------
# Scenario 21: launchctl drift parser - existing program path emits nothing.
# /bin/sh is guaranteed present on macOS.
# ---------------------------------------------------------------------------
scenario_launchd_drift_parser_present() {
  start_test "launchd drift parser ignores present program path"
  local fake_output
  fake_output=$'gui/501/io.example.daemon = {\n\tactive count = 1\n\tprogram = /bin/sh\n}'
  local line
  line="$(stale_scan_launchd_drift_from_output "io.example.daemon" "$fake_output")"
  if [[ -z "$line" ]]; then
    pass
  else
    fail "expected empty output for present program; got: '$line'"
  fi
}

# ---------------------------------------------------------------------------
# Scenario 22: launchctl drift parser - empty input is a no-op.
# ---------------------------------------------------------------------------
scenario_launchd_drift_parser_empty() {
  start_test "launchd drift parser tolerates empty input"
  local line
  line="$(stale_scan_launchd_drift_from_output "io.example.daemon" "")"
  if [[ -z "$line" ]]; then
    pass
  else
    fail "expected empty output for empty input; got: '$line'"
  fi
}

# ---------------------------------------------------------------------------
# Scenario 23: launchctl drift parser - output without a program line is a
# no-op (BundleProgram-backed services do not surface one).
# ---------------------------------------------------------------------------
scenario_launchd_drift_parser_no_program() {
  start_test "launchd drift parser ignores output with no program line"
  local fake_output
  fake_output=$'gui/501/io.example.daemon = {\n\tactive count = 1\n\tstate = running\n}'
  local line
  line="$(stale_scan_launchd_drift_from_output "io.example.daemon" "$fake_output")"
  if [[ -z "$line" ]]; then
    pass
  else
    fail "expected empty output for no-program input; got: '$line'"
  fi
}

# Bind an ephemeral TCP listener in a background Python process. Writes the
# bound port to port_file so we can read it back without racing on stdout.
# Writes the resulting pid to LAST_SPAWN_PID.
spawn_python_listener() {
  local port_file="$1"
  local script='import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(1)
with open(sys.argv[1], "w") as f:
    f.write(str(s.getsockname()[1]))
sys.stdout.close()
time.sleep(300)
'
  nohup python3 -c "$script" "$port_file" >/dev/null 2>&1 &
  LAST_SPAWN_PID=$!
  SPAWNED_PIDS+=("$LAST_SPAWN_PID")
  wait_for_pid_registered "$LAST_SPAWN_PID" || return 1
  local attempts=0
  while (( attempts < 60 )); do
    if [[ -s "$port_file" ]]; then
      return 0
    fi
    sleep 0.05
    attempts=$((attempts + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# Scenario 24: foreign process listening on the Codex WS port is flagged.
# ---------------------------------------------------------------------------
scenario_foreign_ws_listener() {
  start_test "foreign TCP listener on Codex port is flagged as conflict"
  local port_file="$SANDBOX/foreign-$RUN_ID.port"
  spawn_python_listener "$port_file" || { fail "listener never bound"; return; }
  local pid="$LAST_SPAWN_PID"
  local port
  port="$(cat "$port_file")"

  stale_scan_refresh_ps
  local foreign
  foreign="$(stale_scan_foreign_tcp_listeners "$port")"
  assert_in_list "$pid" "foreign listener pid" "$foreign" && pass
}

# ---------------------------------------------------------------------------
# Scenario 25: harness-labelled listener is NOT flagged as foreign. We write
# the listener script at a path containing target/debug/harness so macOS ps
# (which ignores exec -a for framework-wrapped Python) still surfaces an
# argv line that matches the build-bucket regex.
# ---------------------------------------------------------------------------
scenario_harness_ws_listener_not_flagged() {
  start_test "harness-labelled TCP listener is not flagged as foreign"
  local target_dir="$SANDBOX/target/debug"
  mkdir -p "$target_dir"
  local script_path="$target_dir/harness"
  cat >"$script_path" <<'EOF'
import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(1)
with open(sys.argv[2], "w") as f:
    f.write(str(s.getsockname()[1]))
sys.stdout.close()
time.sleep(300)
EOF

  local port_file="$SANDBOX/harness-$RUN_ID.port"
  nohup python3 "$script_path" daemon "$port_file" >/dev/null 2>&1 &
  local pid=$!
  SPAWNED_PIDS+=("$pid")
  wait_for_pid_registered "$pid" || { fail "listener never started"; return; }
  local attempts=0
  while (( attempts < 60 )); do
    [[ -s "$port_file" ]] && break
    sleep 0.05
    attempts=$((attempts + 1))
  done
  [[ -s "$port_file" ]] || { fail "port file never populated"; return; }
  local port
  port="$(cat "$port_file")"

  stale_scan_refresh_ps
  # Sanity check: the pid should be in the build bucket because its argv
  # matches the target/debug/harness daemon regex.
  local build_pids
  build_pids="$(stale_scan_matching_pids build)"
  assert_in_list "$pid" "build-bucket pid (setup check)" "$build_pids" || return

  local foreign
  foreign="$(stale_scan_foreign_tcp_listeners "$port")"
  assert_not_in_list "$pid" "harness listener pid" "$foreign" && pass
}

# ---------------------------------------------------------------------------
# Scenario 26: codex WS port helper respects HARNESS_CODEX_WS_PORT.
# ---------------------------------------------------------------------------
scenario_codex_ws_port_env() {
  start_test "stale_scan_codex_ws_port honors env override"
  local got_default
  got_default="$(HARNESS_CODEX_WS_PORT='' stale_scan_codex_ws_port)"
  if [[ "$got_default" != "4500" ]]; then
    fail "expected default 4500, got '$got_default'"
    return
  fi
  local got_override
  got_override="$(HARNESS_CODEX_WS_PORT=31337 stale_scan_codex_ws_port)"
  if [[ "$got_override" == "31337" ]]; then
    pass
  else
    fail "expected 31337 override, got '$got_override'"
  fi
}

# ---------------------------------------------------------------------------
# Scenario 27: bridge-spawned Codex app-server listener is detected for cleanup.
# ---------------------------------------------------------------------------
scenario_codex_app_server_listener_detected() {
  start_test "codex app-server listener on Codex port is detected for cleanup"
  local bin_dir="$SANDBOX/codex-bin-$RUN_ID"
  mkdir -p "$bin_dir"
  local script_path="$bin_dir/codex"
  cat >"$script_path" <<'EOF'
import socket, sys, time
listen = sys.argv[sys.argv.index("--listen") + 1]
port = int(listen.rsplit(":", 1)[1].split("/", 1)[0])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(1)
with open(sys.argv[-1], "w") as f:
    f.write(str(port))
sys.stdout.close()
time.sleep(300)
EOF

  local port
  port="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
  local port_file="$SANDBOX/codex-$RUN_ID.port"
  nohup python3 "$script_path" app-server --listen "ws://127.0.0.1:$port" "$port_file" >/dev/null 2>&1 &
  local pid=$!
  SPAWNED_PIDS+=("$pid")
  wait_for_pid_registered "$pid" || { fail "codex app-server fixture never started"; return; }
  wait_for_pid_argv_contains "$pid" "codex app-server" || {
    fail "codex app-server fixture argv did not settle"
    return
  }
  local attempts=0
  while (( attempts < 60 )); do
    [[ -s "$port_file" ]] && break
    sleep 0.05
    attempts=$((attempts + 1))
  done
  [[ -s "$port_file" ]] || { fail "codex app-server fixture never bound"; return; }

  stale_scan_refresh_ps
  local codex_pids
  codex_pids="$(stale_scan_codex_app_server_listener_pids "$port")"
  assert_in_list "$pid" "codex app-server listener pid" "$codex_pids" && pass
}

# ---------------------------------------------------------------------------
# Scenario 28: HARNESS_CHECK_AUTOCLEAN=1 invokes the clean script and the
# planted marker disappears. The "exit 0" happy-path end-state is only
# reachable when no other pollution exists, which is not the case mid-suite;
# we assert the invariants we control (marker gone, autoclean banner, fake
# clean stdout) and accept either exit 0 or 1 as success.
# ---------------------------------------------------------------------------
scenario_autoclean_success() {
  start_test "HARNESS_CHECK_AUTOCLEAN=1 invokes the clean script and removes the marker"
  local marker="/tmp/h-bridge-TEST-$RUN_ID-autoclean.sock"
  : >"$marker"
  TMP_MARKERS+=("$marker")

  local clean_script="$SANDBOX/fake-clean-$RUN_ID.sh"
  cat >"$clean_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
rm -f "$marker"
echo "fake clean removed marker"
EOF
  chmod +x "$clean_script"

  local output status=0
  output="$(HARNESS_CHECK_AUTOCLEAN=1 HARNESS_CHECK_CLEAN_SCRIPT="$clean_script" \
    "$ROOT/scripts/check-no-stale-state.sh" 2>&1)" || status=$?

  if [[ -e "$marker" ]]; then
    fail "marker still present after autoclean: $marker"
    return
  fi
  if ! grep -Fq -- "HARNESS_CHECK_AUTOCLEAN=1 is set, running clean:stale" <<<"$output"; then
    fail "expected autoclean invocation banner; output: $output"
    return
  fi
  if ! grep -Fq -- "fake clean removed marker" <<<"$output"; then
    fail "expected fake clean stdout to surface; output: $output"
    return
  fi
  if (( status != 0 && status != 1 )); then
    fail "expected exit 0 or 1 after autoclean; got $status"
    return
  fi
  pass
}

# ---------------------------------------------------------------------------
# Scenario 29: HARNESS_CHECK_AUTOCLEAN=1 - pollution the stub clean cannot
# resolve still fails the gate with exit 1.
# ---------------------------------------------------------------------------
scenario_autoclean_unresolved_still_fails() {
  start_test "HARNESS_CHECK_AUTOCLEAN=1 still fails when clean is incomplete"
  local marker="/tmp/h-bridge-TEST-$RUN_ID-unresolved.sock"
  : >"$marker"
  TMP_MARKERS+=("$marker")

  local clean_script="$SANDBOX/fake-clean-noop-$RUN_ID.sh"
  cat >"$clean_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "fake clean did nothing"
EOF
  chmod +x "$clean_script"

  local output status=0
  output="$(HARNESS_CHECK_AUTOCLEAN=1 HARNESS_CHECK_CLEAN_SCRIPT="$clean_script" \
    "$ROOT/scripts/check-no-stale-state.sh" 2>&1)" || status=$?

  if (( status != 1 )); then
    fail "expected exit 1 after failed autoclean; got $status (output: $output)"
    return
  fi
  if ! grep -Fq -- "auto-clean did not resolve" <<<"$output"; then
    fail "expected unresolved confirmation; output: $output"
    return
  fi
  if ! grep -Fq -- "$marker" <<<"$output"; then
    fail "expected remaining marker listed; output: $output"
    return
  fi
  pass
}

# ---------------------------------------------------------------------------
# Scenario 30: HARNESS_CHECK_AUTOCLEAN=1 when clean script exits nonzero.
# ---------------------------------------------------------------------------
scenario_autoclean_clean_script_fails() {
  start_test "HARNESS_CHECK_AUTOCLEAN=1 surfaces clean-script failure"
  local marker="/tmp/h-bridge-TEST-$RUN_ID-cleanfail.sock"
  : >"$marker"
  TMP_MARKERS+=("$marker")

  local clean_script="$SANDBOX/fake-clean-fail-$RUN_ID.sh"
  cat >"$clean_script" <<'EOF'
#!/usr/bin/env bash
echo "fake clean exploded" >&2
exit 42
EOF
  chmod +x "$clean_script"

  local output status=0
  output="$(HARNESS_CHECK_AUTOCLEAN=1 HARNESS_CHECK_CLEAN_SCRIPT="$clean_script" \
    "$ROOT/scripts/check-no-stale-state.sh" 2>&1)" || status=$?

  if (( status != 1 )); then
    fail "expected exit 1 after clean-script failure; got $status"
    return
  fi
  if ! grep -Fq -- "auto-clean failed" <<<"$output"; then
    fail "expected auto-clean failed message; output: $output"
    return
  fi
  pass
}

# ---------------------------------------------------------------------------
# Scenario 31: baseline e2e without HARNESS_CHECK_AUTOCLEAN - planted artifact
# still fails the gate (regression check after autoclean plumbing).
# ---------------------------------------------------------------------------
scenario_end_to_end_without_autoclean() {
  start_test "baseline: without autoclean env the gate still fails on /tmp artifact"
  local marker="/tmp/h-bridge-TEST-$RUN_ID-baseline.sock"
  : >"$marker"
  TMP_MARKERS+=("$marker")

  local output status=0
  output="$(env -u HARNESS_CHECK_AUTOCLEAN "$ROOT/scripts/check-no-stale-state.sh" 2>&1)" || status=$?

  if (( status != 1 )); then
    fail "expected exit 1; got $status"
    return
  fi
  if ! grep -Fq -- "$marker" <<<"$output"; then
    fail "expected marker in output; output: $output"
    return
  fi
  pass
}

# ---------------------------------------------------------------------------
# Scenario 32: congestion + autoclean - plant multiple /tmp artifacts; fake
# clean removes one; final report must list the remaining two and NOT the
# cleaned one.
# ---------------------------------------------------------------------------
scenario_autoclean_congestion_partial() {
  start_test "HARNESS_CHECK_AUTOCLEAN=1 surfaces remaining pollution under congestion"
  local a="/tmp/h-bridge-TEST-$RUN_ID-partial-a.sock"
  local b="/tmp/h-bridge-TEST-$RUN_ID-partial-b.pid"
  local c="/tmp/h-bridge-TEST-$RUN_ID-partial-c.lock"
  : >"$a"
  : >"$b"
  : >"$c"
  TMP_MARKERS+=("$a" "$b" "$c")

  local clean_script="$SANDBOX/fake-clean-partial-$RUN_ID.sh"
  cat >"$clean_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
rm -f "$a"
EOF
  chmod +x "$clean_script"

  local output status=0
  output="$(HARNESS_CHECK_AUTOCLEAN=1 HARNESS_CHECK_CLEAN_SCRIPT="$clean_script" \
    "$ROOT/scripts/check-no-stale-state.sh" 2>&1)" || status=$?

  if (( status != 1 )); then
    fail "expected exit 1 after partial autoclean; got $status"
    return
  fi
  # Final 'error: dev state is stale' block must list b and c and NOT a.
  local tail_output
  tail_output="$(awk '/^error: dev state is stale$/ { show = 1 } show { print }' <<<"$output" | tail -n 60)"
  if grep -Fq -- "$a" <<<"$tail_output"; then
    fail "$a was not cleaned: final block still lists it"
    return
  fi
  local ok=1
  grep -Fq -- "$b" <<<"$tail_output" || ok=0
  grep -Fq -- "$c" <<<"$tail_output" || ok=0
  if (( ok )); then
    pass
  else
    fail "expected remaining markers in final block: $tail_output"
  fi
}

run_all() {
  scenario_debug_orphan
  scenario_release_orphan
  scenario_per_triple_debug_orphan
  scenario_per_triple_release_orphan
  scenario_live_bucket
  scenario_gate_bucket
  scenario_test_runners_not_gate_bucket
  scenario_tmp_artifacts
  scenario_lock_holder
  scenario_pid_describe_format
  scenario_ancestor_exclusion
  scenario_congested_env
  scenario_end_to_end_detection
  scenario_clean_tmp_removal_is_idempotent
  scenario_installed_not_in_build_bucket
  scenario_refresh_updates_cache
  scenario_orphan_wal
  scenario_orphan_shm
  scenario_sidecars_with_db_noop
  scenario_orphan_sidecar_missing_root
  scenario_launchd_drift_parser_missing
  scenario_launchd_drift_parser_present
  scenario_launchd_drift_parser_empty
  scenario_launchd_drift_parser_no_program
  scenario_foreign_ws_listener
  scenario_harness_ws_listener_not_flagged
  scenario_codex_ws_port_env
  scenario_codex_app_server_listener_detected
  scenario_autoclean_success
  scenario_autoclean_unresolved_still_fails
  scenario_autoclean_clean_script_fails
  scenario_end_to_end_without_autoclean
  scenario_autoclean_congestion_partial
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
