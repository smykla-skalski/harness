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
AGENT_SESSION_ENV_KEYS=(
  HARNESS_AGENT_ID
  CODEX_SESSION_ID
  CODEX_THREAD_ID
  CLAUDE_SESSION_ID
  GEMINI_SESSION_ID
  COPILOT_SESSION_ID
  OPENCODE_SESSION_ID
  VIBE_SESSION_ID
)
ISOLATED_TEST_ENV_KEYS=(
  HARNESS_MONITOR_RUNTIME_PROFILE
  HARNESS_DAEMON_DATA_HOME
  HARNESS_CODEX_WS_PORT
  HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL
  HARNESS_MONITOR_ALLOW_NON_AGENT_RUNTIME_PROFILE
  HARNESS_MONITOR_ALLOW_AGENT_USER_PROFILE
)
SAVED_AGENT_SESSION_ENV=()

unset_agent_session_env() {
  local key
  for key in "${AGENT_SESSION_ENV_KEYS[@]}"; do
    if [[ -n "${!key+x}" ]]; then
      SAVED_AGENT_SESSION_ENV+=("$key=${!key}")
      unset "$key"
    fi
  done
  for key in "${ISOLATED_TEST_ENV_KEYS[@]}"; do
    if [[ -n "${!key+x}" ]]; then
      SAVED_AGENT_SESSION_ENV+=("$key=${!key}")
      unset "$key"
    fi
  done
}

restore_agent_session_env() {
  local entry key value
  for entry in "${SAVED_AGENT_SESSION_ENV[@]}"; do
    key="${entry%%=*}"
    value="${entry#*=}"
    export "$key=$value"
  done
}

unset_agent_session_env
# shellcheck source=scripts/lib/stale-scan.sh
source "$ROOT/scripts/lib/stale-scan.sh"

RUN_ID="$$"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/stale-scan-test-$RUN_ID.XXXXXX")"
TMP_BRIDGE_ROOT="$SANDBOX/tmp-bridge"
mkdir -p "$TMP_BRIDGE_ROOT"
export HARNESS_STALE_SCAN_TMP_ROOT="$TMP_BRIDGE_ROOT"
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
  restore_agent_session_env
}
trap cleanup EXIT

log() {
  printf '%s\n' "$*" >&2
}

last_stale_block() {
  awk '
    /^error: dev state is stale$/ {
      block = $0 ORS
      capture = 1
      next
    }
    capture {
      block = block $0 ORS
    }
    END {
      printf "%s", block
    }
  '
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

wait_for_pid_in_bucket() {
  local pid="$1"
  local bucket="$2"
  local attempts=0
  while (( attempts < 80 )); do
    stale_scan_refresh_ps
    if grep -Fxq -- "$pid" <<<"$(stale_scan_matching_pids "$bucket")"; then
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

spawn_labelled_with_runtime_profile() {
  local profile="$1"
  local label="$2"
  # shellcheck disable=SC2016  # $1 is resolved by the inner bash, not this shell
  nohup env HARNESS_MONITOR_RUNTIME_PROFILE="$profile" \
    bash -c 'exec -a "$1" sleep 300' bash-spawner "$label" >/dev/null 2>&1 &
  LAST_SPAWN_PID=$!
  SPAWNED_PIDS+=("$LAST_SPAWN_PID")
  wait_for_pid_registered "$LAST_SPAWN_PID" || return 1
  wait_for_pid_argv_contains "$LAST_SPAWN_PID" "$label" || return 1
}

spawn_labelled_with_open_lock() {
  local label="$1"
  local lock_path="$2"
  mkdir -p "$(dirname "$lock_path")"
  : >"$lock_path"
  # shellcheck disable=SC2016  # $1/$2 are resolved by the inner bash, not this shell
  nohup bash -c 'exec 9>>"$2"; exec -a "$1" sleep 300' \
    bash-spawner "$label" "$lock_path" >/dev/null 2>&1 &
  LAST_SPAWN_PID=$!
  SPAWNED_PIDS+=("$LAST_SPAWN_PID")
  wait_for_pid_registered "$LAST_SPAWN_PID" || return 1
  wait_for_pid_argv_contains "$LAST_SPAWN_PID" "$label" || return 1
}

spawn_labelled_with_runtime_profile_and_open_lock() {
  local profile="$1"
  local label="$2"
  local lock_path="$3"
  mkdir -p "$(dirname "$lock_path")"
  : >"$lock_path"
  # shellcheck disable=SC2016  # $1/$2 are resolved by the inner bash, not this shell
  nohup env HARNESS_MONITOR_RUNTIME_PROFILE="$profile" \
    bash -c 'exec 9>>"$2"; exec -a "$1" sleep 300' \
    bash-spawner "$label" "$lock_path" >/dev/null 2>&1 &
  LAST_SPAWN_PID=$!
  SPAWNED_PIDS+=("$LAST_SPAWN_PID")
  wait_for_pid_registered "$LAST_SPAWN_PID" || return 1
  wait_for_pid_argv_contains "$LAST_SPAWN_PID" "$label" || return 1
}

spawn_labelled_with_daemon_data_home_and_open_lock() {
  local daemon_data_home="$1"
  local label="$2"
  local lock_path="$3"
  mkdir -p "$(dirname "$lock_path")"
  : >"$lock_path"
  # shellcheck disable=SC2016  # $1/$2 are resolved by the inner bash, not this shell
  nohup env HARNESS_DAEMON_DATA_HOME="$daemon_data_home" \
    bash -c 'exec 9>>"$2"; exec -a "$1" sleep 300' \
    bash-spawner "$label" "$lock_path" >/dev/null 2>&1 &
  LAST_SPAWN_PID=$!
  SPAWNED_PIDS+=("$LAST_SPAWN_PID")
  wait_for_pid_registered "$LAST_SPAWN_PID" || return 1
  wait_for_pid_argv_contains "$LAST_SPAWN_PID" "$label" || return 1
}

kill_spawned_repo_gate_fixtures() {
  stale_scan_refresh_ps
  local gate_pids pid
  local remaining_pids=()
  gate_pids="$(stale_scan_repo_gate_pids "$$")"

  for pid in "${SPAWNED_PIDS[@]}"; do
    [[ -n "$pid" ]] || continue
    if [[ -n "$gate_pids" ]] && grep -Fxq -- "$pid" <<<"$gate_pids"; then
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      continue
    fi
    if kill -0 "$pid" 2>/dev/null; then
      remaining_pids+=("$pid")
    fi
  done

  SPAWNED_PIDS=("${remaining_pids[@]}")
  stale_scan_refresh_ps
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
  wait_for_pid_in_bucket "$LAST_SPAWN_PID" build || return 1
}

spawn_target_harness_with_open_lock() {
  local subpath="$1"
  local subcommand="$2"
  local lock_path="$3"
  local dir="$SANDBOX/$subpath"
  mkdir -p "$dir"
  spawn_labelled_with_open_lock "$dir/harness $subcommand" "$lock_path"
  wait_for_pid_in_bucket "$LAST_SPAWN_PID" build || return 1
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
  spawn_labelled "mise run monitor:test" || { fail "spawn monitor test failed"; return; }
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
  local stem="$TMP_BRIDGE_ROOT/h-bridge-TEST-$RUN_ID"
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
# Scenario 8: profile-scoped scans skip global /tmp bridge artifacts
# ---------------------------------------------------------------------------
scenario_profile_scoped_tmp_artifacts_are_ignored() {
  start_test "profile-scoped scans ignore global /tmp bridge artifacts"
  local marker="$TMP_BRIDGE_ROOT/h-bridge-TEST-$RUN_ID-profile.sock"
  : >"$marker"
  TMP_MARKERS+=("$marker")

  local found
  found="$(HARNESS_DAEMON_DATA_HOME="$SANDBOX/profile-home" stale_scan_tmp_bridge_artifacts)"
  if [[ -z "$found" ]]; then
    pass
  else
    fail "expected profile-scoped /tmp scan to be empty, got: $found"
  fi
}

# ---------------------------------------------------------------------------
# Scenario 9: profile-scoped daemon roots resolve from HARNESS_DAEMON_DATA_HOME
# ---------------------------------------------------------------------------
scenario_profile_scoped_daemon_root() {
  start_test "profile-scoped daemon roots use HARNESS_DAEMON_DATA_HOME"
  local daemon_data_home="$SANDBOX/profile-home"
  local roots
  roots="$(HARNESS_DAEMON_DATA_HOME="$daemon_data_home" stale_scan_daemon_roots)"
  if [[ "$roots" == "$daemon_data_home/harness/daemon" ]]; then
    pass
  else
    fail "expected scoped daemon root, got: $roots"
  fi
}

# ---------------------------------------------------------------------------
# Scenario 9b: cargo-built harness daemon/bridge processes that still hold a
# real Harness lock are live work, not orphan cleanup targets.
# ---------------------------------------------------------------------------
scenario_lock_holding_build_process_not_orphaned() {
  start_test "lock-holding cargo-built harness process is not treated as orphan"
  local fake_root="$SANDBOX/profile-build-root-$RUN_ID/harness/daemon"
  local lock_path="$fake_root/bridge.lock"
  spawn_target_harness_with_open_lock "target/debug" bridge "$lock_path" || {
    fail "spawn failed"
    return
  }
  local pid="$LAST_SPAWN_PID"

  sleep 0.3
  stale_scan_refresh_ps
  local build_pids orphans
  build_pids="$(stale_scan_matching_pids build)"
  orphans="$(stale_scan_orphan_harness_build_pids)"
  local ok=1
  assert_in_list "$pid" "build-bucket pid" "$build_pids" || ok=0
  assert_not_in_list "$pid" "orphan build pid" "$orphans" || ok=0
  if (( ok )); then pass; fi
}

# ---------------------------------------------------------------------------
# Scenario 10: custom-root lock holder detection via lsof
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
# Scenario 10a: profile-scoped live lock holders are deliberate isolated work
# and must not be treated as stale cleanup targets.
# ---------------------------------------------------------------------------
scenario_profiled_live_lock_holder_not_stale() {
  start_test "profile-scoped live lock holder is not stale pollution"
  local fake_root="$SANDBOX/profile-live-root-$RUN_ID/harness/daemon"
  local lock_path="$fake_root/bridge.lock"
  spawn_labelled_with_runtime_profile_and_open_lock \
    "bartsmykla" \
    "/opt/fake/harness bridge start" \
    "$lock_path" || {
    fail "spawn failed"
    return
  }
  local pid="$LAST_SPAWN_PID"

  sleep 0.3
  stale_scan_refresh_ps
  local holders conflicting
  holders="$(stale_scan_root_lock_holder_pids "$fake_root")"
  conflicting="$(stale_scan_root_conflicting_lock_holder_pids "$fake_root")"
  local ok=1
  assert_in_list "$pid" "lock-holder pid" "$holders" || ok=0
  assert_not_in_list "$pid" "conflicting lock-holder pid" "$conflicting" || ok=0
  if (( ok )); then pass; fi
}

# ---------------------------------------------------------------------------
# Scenario 10b: data-home-scoped live lock holders are deliberate isolated work
# even if the runtime-profile env is absent.
# ---------------------------------------------------------------------------
scenario_data_home_scoped_live_lock_holder_not_stale() {
  start_test "data-home-scoped live lock holder is not stale pollution"
  local daemon_data_home="$SANDBOX/runtime-profiles/bartsmykla"
  local fake_root="$daemon_data_home/harness/daemon"
  local lock_path="$fake_root/bridge.lock"
  spawn_labelled_with_daemon_data_home_and_open_lock \
    "$daemon_data_home" \
    "/opt/fake/harness bridge start" \
    "$lock_path" || {
    fail "spawn failed"
    return
  }
  local pid="$LAST_SPAWN_PID"

  sleep 0.3
  stale_scan_refresh_ps
  local holders conflicting
  holders="$(stale_scan_root_lock_holder_pids "$fake_root")"
  conflicting="$(stale_scan_root_conflicting_lock_holder_pids "$fake_root")"
  local ok=1
  assert_in_list "$pid" "lock-holder pid" "$holders" || ok=0
  assert_not_in_list "$pid" "conflicting lock-holder pid" "$conflicting" || ok=0
  if (( ok )); then pass; fi
}

# ---------------------------------------------------------------------------
# Scenario 10c: unscoped live lock holders remain cleanup targets for the
# broader shared-root stale cleanup path.
# ---------------------------------------------------------------------------
scenario_unscoped_live_lock_holder_still_stale() {
  start_test "unscoped live lock holder remains stale cleanup target"
  local fake_root="$SANDBOX/unscoped-live-root-$RUN_ID/harness/daemon"
  local lock_path="$fake_root/bridge.lock"
  spawn_labelled_with_open_lock "/opt/fake/harness bridge start" "$lock_path" || {
    fail "spawn failed"
    return
  }
  local pid="$LAST_SPAWN_PID"

  sleep 0.3
  stale_scan_refresh_ps
  local conflicting
  conflicting="$(stale_scan_root_conflicting_lock_holder_pids "$fake_root")"
  assert_in_list "$pid" "conflicting lock-holder pid" "$conflicting" && pass
}

# ---------------------------------------------------------------------------
# Scenario 10d: default clean:stale is now the safe scrub. It must preserve
# live shared Monitor state while still reaping orphan build processes.
# ---------------------------------------------------------------------------
scenario_clean_stale_safe_mode_preserves_live_shared_state() {
  start_test "clean:stale safe scrub preserves live shared Monitor state"
  local fake_home="$SANDBOX/clean-safe-home-$RUN_ID"
  local fake_bin="$SANDBOX/clean-safe-bin-$RUN_ID"
  local app_group_id="$STALE_SCAN_APP_GROUP_ID"
  local legacy_root="$fake_home/Library/Application Support/harness/daemon"
  local legacy_lock="$legacy_root/daemon.lock"
  local legacy_state="$legacy_root/bridge.json"
  local launchctl_log="$SANDBOX/clean-safe-launchctl-$RUN_ID.log"
  local osascript_log="$SANDBOX/clean-safe-osascript-$RUN_ID.log"
  local output status=0
  local live_pid orphan_pid codex_pid codex_port codex_port_file

  mkdir -p "$fake_bin" "$legacy_root"
  cat >"$fake_bin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$fake_bin/launchctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$launchctl_log"
exit 0
EOF
  cat >"$fake_bin/osascript" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$osascript_log"
exit 0
EOF
  chmod +x "$fake_bin/pgrep" "$fake_bin/launchctl" "$fake_bin/osascript"
  printf '{"bridge":"legacy"}\n' >"$legacy_state"

  spawn_labelled_with_open_lock "/opt/fake/harness daemon serve" "$legacy_lock" || {
    fail "spawn live holder failed"
    return
  }
  live_pid="$LAST_SPAWN_PID"
  spawn_target_harness "target/release" bridge || {
    fail "spawn orphan build failed"
    return
  }
  orphan_pid="$LAST_SPAWN_PID"
  codex_port="$(allocate_free_tcp_port)"
  codex_port_file="$SANDBOX/codex-safe-$RUN_ID.port"
  spawn_codex_app_server_listener "$codex_port" "$codex_port_file" || {
    fail "spawn codex app-server failed"
    return
  }
  codex_pid="$LAST_SPAWN_PID"

  sleep 0.3
  output="$(
    env \
      -u HARNESS_DAEMON_DATA_HOME \
      -u HARNESS_MONITOR_RUNTIME_PROFILE \
      HOME="$fake_home" \
      PATH="$fake_bin:$PATH" \
      HARNESS_APP_GROUP_ID="$app_group_id" \
      HARNESS_CODEX_WS_PORT="$codex_port" \
      HARNESS_CHECK_IGNORE_REPO_GATE_HELPERS=1 \
      HARNESS_STALE_CLEANUP_LEASE_HELD=1 \
      HARNESS_MONITOR_OSASCRIPT_BIN="$fake_bin/osascript" \
      HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL="io.harnessmonitor.daemon.test" \
      "$ROOT/scripts/clean-stale-state.sh" 2>&1
  )" || status=$?

  if (( status != 0 )); then
    fail "clean-stale-state.sh failed: $output"
    return
  fi

  sleep 0.3
  if ! kill -0 "$live_pid" 2>/dev/null; then
    fail "live shared holder died during safe clean:stale"
    return
  fi
  if kill -0 "$orphan_pid" 2>/dev/null; then
    fail "orphan build process survived safe clean:stale"
    return
  fi
  if ! kill -0 "$codex_pid" 2>/dev/null; then
    fail "live codex app-server died during safe clean:stale"
    return
  fi
  if [[ ! -e "$legacy_lock" || ! -e "$legacy_state" ]]; then
    fail "safe clean:stale wiped live shared root"
    return
  fi
  if grep -Fq -- "quitting Harness Monitor app..." <<<"$output"; then
    fail "safe clean:stale attempted to quit the app"
    return
  fi
  if grep -Fq -- "stopping launchd daemon" <<<"$output"; then
    fail "safe clean:stale attempted to stop launchd"
    return
  fi
  if [[ -s "$launchctl_log" || -s "$osascript_log" ]]; then
    fail "safe clean:stale called live-reset tools unexpectedly"
    return
  fi
  pass
}

# ---------------------------------------------------------------------------
# Scenario 10e: full clean:stale reset preserves a profiled live bridge root
# while still reaping stale unscoped holders and orphan build processes.
# ---------------------------------------------------------------------------
scenario_clean_stale_full_reset_preserves_profiled_bridge_end_to_end() {
  start_test "clean:stale full reset preserves profiled bridge while reaping stale shared holders"
  local fake_home="$SANDBOX/clean-home-$RUN_ID"
  local fake_bin="$SANDBOX/clean-bin-$RUN_ID"
  local app_group_id="$STALE_SCAN_APP_GROUP_ID"
  local shared_root="$fake_home/Library/Group Containers/$app_group_id/harness/daemon"
  local legacy_root="$fake_home/Library/Application Support/harness/daemon"
  local shared_lock="$shared_root/bridge.lock"
  local legacy_lock="$legacy_root/daemon.lock"
  local shared_state="$shared_root/bridge.json"
  local legacy_state="$legacy_root/bridge.json"
  local output status=0
  local profiled_pid unscoped_pid orphan_pid codex_pid codex_port codex_port_file

  mkdir -p "$fake_bin" "$shared_root" "$legacy_root"
  cat >"$fake_bin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat >"$fake_bin/launchctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$fake_bin/pgrep" "$fake_bin/launchctl"
  printf '{"bridge":"profiled"}\n' >"$shared_state"
  printf '{"bridge":"legacy"}\n' >"$legacy_state"

  spawn_labelled_with_runtime_profile_and_open_lock \
    "bartsmykla" \
    "$SANDBOX/target/debug/harness bridge" \
    "$shared_lock" || {
    fail "spawn profiled holder failed"
    return
  }
  profiled_pid="$LAST_SPAWN_PID"
  spawn_labelled_with_open_lock "/opt/fake/harness daemon serve" "$legacy_lock" || {
    fail "spawn unscoped holder failed"
    return
  }
  unscoped_pid="$LAST_SPAWN_PID"
  spawn_target_harness "target/release" bridge || {
    fail "spawn orphan build failed"
    return
  }
  orphan_pid="$LAST_SPAWN_PID"
  codex_port="$(allocate_free_tcp_port)"
  codex_port_file="$SANDBOX/codex-full-$RUN_ID.port"
  spawn_codex_app_server_listener "$codex_port" "$codex_port_file" || {
    fail "spawn codex app-server failed"
    return
  }
  codex_pid="$LAST_SPAWN_PID"

  sleep 0.3
  output="$(
    env \
      -u HARNESS_DAEMON_DATA_HOME \
      -u HARNESS_MONITOR_RUNTIME_PROFILE \
      HOME="$fake_home" \
      PATH="$fake_bin:$PATH" \
      HARNESS_APP_GROUP_ID="$app_group_id" \
      HARNESS_CODEX_WS_PORT="$codex_port" \
      HARNESS_CHECK_IGNORE_REPO_GATE_HELPERS=1 \
      HARNESS_STALE_CLEANUP_ALLOW_LIVE_RESET=1 \
      HARNESS_STALE_CLEANUP_LEASE_HELD=1 \
      HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL="io.harnessmonitor.daemon.test" \
      "$ROOT/scripts/clean-stale-state.sh" 2>&1
  )" || status=$?

  if (( status != 0 )); then
    fail "clean-stale-state.sh failed: $output"
    return
  fi

  sleep 0.3
  if ! kill -0 "$profiled_pid" 2>/dev/null; then
    fail "profiled bridge pid died during clean:stale"
    return
  fi
  if kill -0 "$unscoped_pid" 2>/dev/null; then
    fail "unscoped live holder survived clean:stale"
    return
  fi
  if kill -0 "$orphan_pid" 2>/dev/null; then
    fail "orphan build process survived clean:stale"
    return
  fi
  if kill -0 "$codex_pid" 2>/dev/null; then
    fail "stale codex app-server survived full clean:stale"
    return
  fi
  if [[ ! -e "$shared_lock" || ! -e "$shared_state" ]]; then
    fail "profiled live root was wiped during clean:stale"
    return
  fi
  local legacy_holders
  legacy_holders="$(stale_scan_root_lock_holder_pids "$legacy_root")"
  if [[ -n "$legacy_holders" ]]; then
    fail "legacy stale root still has live lock holders after clean:stale"
    return
  fi
  if [[ -e "$legacy_state" ]]; then
    fail "legacy stale bridge state was not wiped during clean:stale"
    return
  fi
  pass
}

# ---------------------------------------------------------------------------
# Scenario 11: pid_describe formats PID/ETIME/COMMAND
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
# Scenario 10b: gate helpers in sibling worktrees that share the same git
# common-root must still block cleanup on shared DerivedData.
# ---------------------------------------------------------------------------
scenario_common_root_gate_helper_detection() {
  start_test "common-root sibling gate helper is detected across worktrees"
  local main_root="$SANDBOX/common-root-main"
  local sibling_root="$SANDBOX/common-root-sibling"
  local tracked_file="$main_root/README.md"
  local branch_name="common-root-gate-$RUN_ID"
  local saved_root saved_common_root gate_pids
  local ok=1

  mkdir -p "$main_root"
  git -C "$main_root" init >/dev/null 2>&1 || { fail "git init failed"; return; }
  printf 'common root test\n' >"$tracked_file"
  git -C "$main_root" add README.md >/dev/null 2>&1 || { fail "git add failed"; return; }
  git -C "$main_root" -c user.name='Test User' -c user.email='test@example.com' \
    commit -m 'init' >/dev/null 2>&1 || { fail "git commit failed"; return; }
  git -C "$main_root" branch "$branch_name" >/dev/null 2>&1 || { fail "git branch failed"; return; }
  git -C "$main_root" worktree add "$sibling_root" "$branch_name" >/dev/null 2>&1 || {
    fail "git worktree add failed"
    return
  }

  pushd "$sibling_root" >/dev/null || { fail "pushd $sibling_root failed"; return; }
  # shellcheck disable=SC2016  # $1 is resolved by the inner bash, not this shell
  nohup bash -c 'exec -a "$1" sleep 300' bash-spawner "mise run check" >/dev/null 2>&1 &
  local sibling_pid=$!
  popd >/dev/null || { fail "popd failed"; return; }
  SPAWNED_PIDS+=("$sibling_pid")
  wait_for_pid_registered "$sibling_pid" || { fail "sibling pid never registered"; return; }
  sleep 0.3

  saved_root="$STALE_SCAN_ROOT"
  saved_common_root="$STALE_SCAN_COMMON_REPO_ROOT"
  STALE_SCAN_ROOT="$main_root"
  STALE_SCAN_COMMON_REPO_ROOT="$(resolve_common_repo_root "$main_root")"
  stale_scan_refresh_ps
  gate_pids="$(stale_scan_repo_gate_pids "$$")"
  STALE_SCAN_ROOT="$saved_root"
  STALE_SCAN_COMMON_REPO_ROOT="$saved_common_root"
  stale_scan_refresh_ps

  assert_in_list "$sibling_pid" "common-root sibling gate pid" "$gate_pids" || ok=0
  if (( ok )); then pass; fi
}

# ---------------------------------------------------------------------------
# Scenario 10c: profile-scoped lanes only conflict with same-profile repo gate
# helpers; other isolated profiles are allowed to coexist in the same checkout.
# ---------------------------------------------------------------------------
scenario_profile_scoped_gate_helper_ignores_other_profiles() {
  start_test "profile-scoped repo gate helper scan ignores other profiles"
  local saved_profile_set=0
  local saved_profile=""
  local saved_daemon_data_home_set=0
  local saved_daemon_data_home=""
  local gate_pids user_pid agent_pid unscoped_pid
  local ok=1

  if [[ -n "${HARNESS_MONITOR_RUNTIME_PROFILE+x}" ]]; then
    saved_profile_set=1
    saved_profile="$HARNESS_MONITOR_RUNTIME_PROFILE"
  fi
  if [[ -n "${HARNESS_DAEMON_DATA_HOME+x}" ]]; then
    saved_daemon_data_home_set=1
    saved_daemon_data_home="$HARNESS_DAEMON_DATA_HOME"
  fi

  export HARNESS_MONITOR_RUNTIME_PROFILE="bartsmykla"
  unset HARNESS_DAEMON_DATA_HOME

  pushd "$ROOT" >/dev/null || {
    fail "pushd $ROOT failed"
    return
  }
  spawn_labelled_with_runtime_profile "bartsmykla" \
    "apps/harness-monitor-macos/Scripts/test-swift.sh" || ok=0
  user_pid="$LAST_SPAWN_PID"
  spawn_labelled_with_runtime_profile "agent-sibling" \
    "apps/harness-monitor-macos/Scripts/build-for-testing.sh" || ok=0
  agent_pid="$LAST_SPAWN_PID"
  spawn_labelled "apps/harness-monitor-macos/Scripts/xcodebuild-with-lock.sh" || ok=0
  unscoped_pid="$LAST_SPAWN_PID"
  popd >/dev/null || {
    fail "popd failed"
    ok=0
  }

  sleep 0.3
  stale_scan_refresh_ps
  gate_pids="$(stale_scan_repo_gate_pids "$$")"

  if (( saved_profile_set )); then
    export HARNESS_MONITOR_RUNTIME_PROFILE="$saved_profile"
  else
    unset HARNESS_MONITOR_RUNTIME_PROFILE
  fi
  if (( saved_daemon_data_home_set )); then
    export HARNESS_DAEMON_DATA_HOME="$saved_daemon_data_home"
  else
    unset HARNESS_DAEMON_DATA_HOME
  fi

  assert_in_list "$user_pid" "same-profile gate pid" "$gate_pids" || ok=0
  assert_not_in_list "$agent_pid" "other-profile gate pid" "$gate_pids" || ok=0
  assert_in_list "$unscoped_pid" "unscoped gate pid" "$gate_pids" || ok=0
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
  local marker="$TMP_BRIDGE_ROOT/h-bridge-TEST-$RUN_ID-e2e.sock"
  : >"$marker"
  TMP_MARKERS+=("$marker")

  local output status=0
  # Unset auto-clean so the planted artifact causes the script to fail, not self-heal.
  output="$(env -u HARNESS_CHECK_AUTOCLEAN HARNESS_CHECK_IGNORE_REPO_GATE_HELPERS=1 \
    "$ROOT/scripts/check-no-stale-state.sh" 2>&1)" || status=$?

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
  local marker="$TMP_BRIDGE_ROOT/h-bridge-TEST-$RUN_ID-clean.sock"
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
# Scenario 17: ps snapshot caching - refreshing produces updated view.
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
# Scenario 18: refreshing the ps snapshot must also invalidate the cached
# pid->ppid map. Otherwise repo-gate ancestor exclusion can reuse stale
# lineage and flag the current lane's own parent helper as foreign.
# ---------------------------------------------------------------------------
scenario_refresh_invalidates_ppid_map() {
  start_test "stale_scan_refresh_ps invalidates cached pid->ppid map"
  stale_scan_refresh_ps
  local _unused
  _unused="$(stale_scan_parent_pid "$$")"

  pushd "$ROOT" >/dev/null || { fail "pushd $ROOT failed"; return; }
  # shellcheck disable=SC2016  # $1 is resolved by the inner bash, not this shell
  nohup bash -c 'exec -a "$1" sleep 300' bash-spawner "mise run check" >/dev/null 2>&1 &
  local sibling_pid=$!
  popd >/dev/null || { fail "popd failed"; return; }
  SPAWNED_PIDS+=("$sibling_pid")
  wait_for_pid_registered "$sibling_pid" || { fail "sibling pid never registered"; return; }
  sleep 0.3

  stale_scan_refresh_ps
  local sibling_parent
  sibling_parent="$(stale_scan_parent_pid "$sibling_pid")"
  if [[ -z "$sibling_parent" ]]; then
    fail "refreshed ppid map did not include sibling pid $sibling_pid"
    return
  fi

  pass
}

# ---------------------------------------------------------------------------
# Scenario 19: SQLite sidecar orphan detection - .db-wal present, .db absent.
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
# Scenario 20: SQLite sidecar orphan detection - .db-shm present, .db absent.
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
# Scenario 21: sidecars alongside a live harness.db are NOT flagged. The DB
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
# Scenario 22: nonexistent daemon root is a clean no-op (never errors).
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
# Scenario 23: launchctl drift parser - missing program path emits drift line.
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
# Scenario 24: launchctl drift parser - existing program path emits nothing.
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
# Scenario 25: launchctl drift parser - empty input is a no-op.
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
# Scenario 26: launchctl drift parser - output without a program line is a
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

allocate_free_tcp_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

spawn_codex_app_server_listener() {
  local port="$1"
  local port_file="$2"
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

  nohup python3 "$script_path" app-server --listen "ws://127.0.0.1:$port" "$port_file" >/dev/null 2>&1 &
  LAST_SPAWN_PID=$!
  SPAWNED_PIDS+=("$LAST_SPAWN_PID")
  wait_for_pid_registered "$LAST_SPAWN_PID" || return 1
  wait_for_pid_argv_contains "$LAST_SPAWN_PID" "codex app-server" || return 1
  local attempts=0
  while (( attempts < 60 )); do
    [[ -s "$port_file" ]] && return 0
    sleep 0.05
    attempts=$((attempts + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# Scenario 27: foreign process listening on the Codex WS port is flagged.
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
# Scenario 28: harness-labelled listener is NOT flagged as foreign. We write
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
# Scenario 29: codex WS port helper respects HARNESS_CODEX_WS_PORT.
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
# Scenario 30: orphan bridge-spawned Codex app-server listener is detected for
# cleanup when the current lane has no live lock holder.
# ---------------------------------------------------------------------------
scenario_codex_app_server_listener_detected() {
  start_test "codex app-server listener on Codex port is detected for cleanup"
  local daemon_data_home="$SANDBOX/runtime-profiles/codex-detect"
  local port
  port="$(allocate_free_tcp_port)"
  local port_file="$SANDBOX/codex-$RUN_ID.port"
  spawn_codex_app_server_listener "$port" "$port_file" || {
    fail "codex app-server fixture never bound"
    return
  }
  local pid="$LAST_SPAWN_PID"

  stale_scan_refresh_ps
  local codex_pids
  codex_pids="$(HARNESS_DAEMON_DATA_HOME="$daemon_data_home" stale_scan_codex_app_server_listener_pids "$port")"
  assert_in_list "$pid" "codex app-server listener pid" "$codex_pids" && pass
}

# ---------------------------------------------------------------------------
# Scenario 31: live current-lane Codex app-server listener is not stale while
# its owning Harness lock holder is still alive.
# ---------------------------------------------------------------------------
scenario_live_codex_app_server_listener_not_stale() {
  start_test "live codex app-server listener on current lane is not stale"
  local daemon_data_home="$SANDBOX/runtime-profiles/codex-live"
  local fake_root="$daemon_data_home/harness/daemon"
  local lock_path="$fake_root/bridge.lock"
  local port port_file pid

  spawn_labelled_with_daemon_data_home_and_open_lock \
    "$daemon_data_home" \
    "/opt/fake/harness bridge start" \
    "$lock_path" || {
    fail "spawn live holder failed"
    return
  }
  port="$(allocate_free_tcp_port)"
  port_file="$SANDBOX/codex-live-$RUN_ID.port"
  spawn_codex_app_server_listener "$port" "$port_file" || {
    fail "codex app-server fixture never bound"
    return
  }
  pid="$LAST_SPAWN_PID"

  stale_scan_refresh_ps
  local codex_pids foreign ok=1
  codex_pids="$(HARNESS_DAEMON_DATA_HOME="$daemon_data_home" stale_scan_codex_app_server_listener_pids "$port")"
  foreign="$(HARNESS_DAEMON_DATA_HOME="$daemon_data_home" stale_scan_foreign_tcp_listeners "$port")"
  assert_not_in_list "$pid" "codex app-server listener pid" "$codex_pids" || ok=0
  assert_not_in_list "$pid" "foreign listener pid" "$foreign" || ok=0
  if (( ok )); then pass; fi
}

# ---------------------------------------------------------------------------
# Scenario 32: parentless xcodebuild wrapper without surviving lease metadata
# is detected as a stale orphan.
# ---------------------------------------------------------------------------
scenario_orphan_monitor_wrapper_detected() {
  start_test "parentless xcodebuild wrapper without lease metadata is detected"
  local derived_data_path="$SANDBOX/orphan-derived"
  mkdir -p "$derived_data_path"

  _stale_scan_ps_snapshot=$'12345 1 00:10 /bin/bash '"$ROOT"'/apps/harness-monitor-macos/Scripts/xcodebuild-with-lock.sh -derivedDataPath '"$derived_data_path"' -scheme HarnessMonitor build'
  _stale_scan_ppid_map=""

  local pids
  pids="$(stale_scan_orphan_monitor_wrapper_pids)"
  assert_in_list "12345" "orphan monitor wrapper pid" "$pids" && pass
}

# ---------------------------------------------------------------------------
# Scenario 29: parentless xcodebuild wrapper with live owner metadata is not
# treated as stale just because its parent is gone.
# ---------------------------------------------------------------------------
scenario_monitor_wrapper_with_owner_metadata_not_flagged() {
  start_test "parentless xcodebuild wrapper with owner lease metadata is not flagged"
  local derived_data_path="$SANDBOX/live-owner-derived"
  mkdir -p "$derived_data_path/.xcodebuild.lock/owner"
  cat >"$derived_data_path/.xcodebuild.lock/owner/lease.env" <<EOF
LOCK_PROTOCOL_VERSION=1
LOCK_PID=22334
EOF

  _stale_scan_ps_snapshot=$'22334 1 00:10 /bin/bash '"$ROOT"'/apps/harness-monitor-macos/Scripts/xcodebuild-with-lock.sh -derivedDataPath '"$derived_data_path"' -scheme HarnessMonitor build'
  _stale_scan_ppid_map=""

  local pids
  pids="$(stale_scan_orphan_monitor_wrapper_pids)"
  assert_not_in_list "22334" "live owner wrapper pid" "$pids" && pass
}

# ---------------------------------------------------------------------------
# Scenario 29b: xcodebuild lock cleanup must treat a recorded live mutator as
# active work even if the wrapper owner pid itself is gone.
# ---------------------------------------------------------------------------
scenario_xcodebuild_lock_live_mutator_detected() {
  start_test "xcodebuild lock runtime metadata keeps live mutator from being treated as stale"
  local lock_path="$SANDBOX/live-mutator-lock/.xcodebuild.lock"
  local owner_hostname mutator_command mutator_start
  mkdir -p "$lock_path/owner"

  /bin/sleep 300 &
  local mutator_pid=$!
  SPAWNED_PIDS+=("$mutator_pid")
  owner_hostname="$(/bin/hostname)"
  mutator_command="$(ps -p "$mutator_pid" -o command= 2>/dev/null | sed 's/^[[:space:]]*//' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/[[:space:]]$//')"
  mutator_start="$(ps -p "$mutator_pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]\+/ /g; s/[[:space:]]$//')"

  cat >"$lock_path/owner/lease.env" <<EOF
LOCK_PROTOCOL_VERSION=1
LOCK_RESOURCE=test-resource
LOCK_ROLE=owner
LOCK_OWNER_ID=dead-wrapper
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
  cat >"$lock_path/owner/runtime.env" <<EOF
LOCK_RUNTIME_VERSION=1
LOCK_RESOURCE=test-resource
LOCK_HOSTNAME=$owner_hostname
LOCK_COMMON_REPO_ROOT=$ROOT
LOCK_MUTATOR_PID=$mutator_pid
LOCK_MUTATOR_COMMAND=$mutator_command
LOCK_MUTATOR_PROCESS_START=$mutator_start
EOF

  if stale_scan_xcodebuild_lock_has_live_work "$lock_path"; then
    pass
  else
    fail "lock helper treated a live mutator as stale"
  fi
}

# ---------------------------------------------------------------------------
# Scenario 30: HARNESS_CHECK_AUTOCLEAN=1 invokes the clean script in safe mode
# and the planted marker disappears. The "exit 0" happy-path end-state is only
# reachable when no other pollution exists, which is not the case mid-suite;
# we assert the invariants we control (marker gone, autoclean banner, fake
# clean stdout, safe-reset env) and accept either exit 0 or 1 as success.
# ---------------------------------------------------------------------------
scenario_autoclean_success() {
  start_test "HARNESS_CHECK_AUTOCLEAN=1 invokes the clean script and removes the marker"
  kill_spawned_repo_gate_fixtures
  local marker="$TMP_BRIDGE_ROOT/h-bridge-TEST-$RUN_ID-autoclean.sock"
  : >"$marker"
  TMP_MARKERS+=("$marker")

  local clean_script="$SANDBOX/fake-clean-$RUN_ID.sh"
  cat >"$clean_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "fake clean allow_live_reset=\${HARNESS_STALE_CLEANUP_ALLOW_LIVE_RESET:-unset}"
rm -f "$marker"
echo "fake clean removed marker"
EOF
  chmod +x "$clean_script"

  local output status=0
  output="$(HARNESS_CHECK_AUTOCLEAN=1 HARNESS_CHECK_IGNORE_REPO_GATE_HELPERS=1 HARNESS_CHECK_CLEAN_SCRIPT="$clean_script" \
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
  if ! grep -Fq -- "fake clean allow_live_reset=0" <<<"$output"; then
    fail "expected autoclean to force safe cleanup mode; output: $output"
    return
  fi
  if (( status != 0 && status != 1 )); then
    fail "expected exit 0 or 1 after autoclean; got $status"
    return
  fi
  pass
}

# ---------------------------------------------------------------------------
# Scenario 31: HARNESS_CHECK_AUTOCLEAN=1 - pollution the stub clean cannot
# resolve still fails the gate with exit 1.
# ---------------------------------------------------------------------------
scenario_autoclean_unresolved_still_fails() {
  start_test "HARNESS_CHECK_AUTOCLEAN=1 still fails when clean is incomplete"
  kill_spawned_repo_gate_fixtures
  local marker="$TMP_BRIDGE_ROOT/h-bridge-TEST-$RUN_ID-unresolved.sock"
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
  output="$(HARNESS_CHECK_AUTOCLEAN=1 HARNESS_CHECK_IGNORE_REPO_GATE_HELPERS=1 HARNESS_CHECK_CLEAN_SCRIPT="$clean_script" \
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
# Scenario 32: HARNESS_CHECK_AUTOCLEAN=1 when clean script exits nonzero.
# ---------------------------------------------------------------------------
scenario_autoclean_clean_script_fails() {
  start_test "HARNESS_CHECK_AUTOCLEAN=1 surfaces clean-script failure"
  kill_spawned_repo_gate_fixtures
  local marker="$TMP_BRIDGE_ROOT/h-bridge-TEST-$RUN_ID-cleanfail.sock"
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
  output="$(HARNESS_CHECK_AUTOCLEAN=1 HARNESS_CHECK_IGNORE_REPO_GATE_HELPERS=1 HARNESS_CHECK_CLEAN_SCRIPT="$clean_script" \
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
# Scenario 33: baseline e2e without HARNESS_CHECK_AUTOCLEAN - planted artifact
# still fails the gate (regression check after autoclean plumbing).
# ---------------------------------------------------------------------------
scenario_end_to_end_without_autoclean() {
  start_test "baseline: without autoclean env the gate still fails on /tmp artifact"
  local marker="$TMP_BRIDGE_ROOT/h-bridge-TEST-$RUN_ID-baseline.sock"
  : >"$marker"
  TMP_MARKERS+=("$marker")

  local output status=0
  output="$(env -u HARNESS_CHECK_AUTOCLEAN \
    "$ROOT/scripts/check-no-stale-state.sh" 2>&1)" || status=$?

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
# Scenario 34: congestion + autoclean - plant multiple /tmp artifacts; fake
# clean removes one; final report must list the remaining two and NOT the
# cleaned one.
# ---------------------------------------------------------------------------
scenario_autoclean_congestion_partial() {
  start_test "HARNESS_CHECK_AUTOCLEAN=1 surfaces remaining pollution under congestion"
  kill_spawned_repo_gate_fixtures
  local a="$TMP_BRIDGE_ROOT/h-bridge-TEST-$RUN_ID-partial-a.sock"
  local b="$TMP_BRIDGE_ROOT/h-bridge-TEST-$RUN_ID-partial-b.pid"
  local c="$TMP_BRIDGE_ROOT/h-bridge-TEST-$RUN_ID-partial-c.lock"
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
  output="$(HARNESS_CHECK_AUTOCLEAN=1 HARNESS_CHECK_IGNORE_REPO_GATE_HELPERS=1 HARNESS_CHECK_CLEAN_SCRIPT="$clean_script" \
    "$ROOT/scripts/check-no-stale-state.sh" 2>&1)" || status=$?

  if (( status != 1 )); then
    fail "expected exit 1 after partial autoclean; got $status"
    return
  fi
  # Final 'error: dev state is stale' block must list b and c and NOT a. Parse
  # only the last stale block so unrelated ambient pollution does not evict the
  # markers we care about from a fixed-size tail window.
  local final_block
  final_block="$(last_stale_block <<<"$output")"
  if grep -Fq -- "$a" <<<"$final_block"; then
    fail "$a was not cleaned: final block still lists it"
    return
  fi
  local ok=1
  grep -Fq -- "$b" <<<"$final_block" || ok=0
  grep -Fq -- "$c" <<<"$final_block" || ok=0
  if (( ok )); then
    pass
  else
    fail "expected remaining markers in final block: $final_block"
  fi
}

# ---------------------------------------------------------------------------
# Scenario 35: live repo-local gate helpers are not stale pollution, but they
# must still block auto-clean so shared repo state is not reset under active
# build/check workers.
# ---------------------------------------------------------------------------
scenario_autoclean_blocks_on_live_repo_gate_helpers() {
  start_test "HARNESS_CHECK_AUTOCLEAN=1 defers while live repo gate helpers run"
  kill_spawned_repo_gate_fixtures

  pushd "$ROOT" >/dev/null || { fail "pushd $ROOT failed"; return; }
  # shellcheck disable=SC2016  # $1 is resolved by the inner bash, not this shell
  nohup bash -c 'exec -a "$1" sleep 300' bash-spawner "mise run check" >/dev/null 2>&1 &
  local sibling_pid=$!
  popd >/dev/null || { fail "popd failed"; return; }
  SPAWNED_PIDS+=("$sibling_pid")
  wait_for_pid_registered "$sibling_pid" || { fail "sibling pid never registered"; return; }
  sleep 0.3

  local marker="$TMP_BRIDGE_ROOT/h-bridge-TEST-$RUN_ID-live-helper.sock"
  : >"$marker"
  TMP_MARKERS+=("$marker")

  local clean_script="$SANDBOX/fake-clean-live-helper-$RUN_ID.sh"
  local clean_marker="$SANDBOX/fake-clean-live-helper-$RUN_ID.was-run"
  cat >"$clean_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
touch "$clean_marker"
rm -f "$marker"
echo "fake clean ran with live helper present"
EOF
  chmod +x "$clean_script"

  local output status=0
  output="$(HARNESS_CHECK_AUTOCLEAN=1 HARNESS_CHECK_CLEAN_SCRIPT="$clean_script" \
    "$ROOT/scripts/check-no-stale-state.sh" 2>&1)" || status=$?

  if (( status != 1 )); then
    fail "expected exit 1 when autoclean is blocked by a live helper; got $status (output: $output)"
    return
  fi
  if [[ -e "$clean_marker" ]]; then
    fail "fake clean ran despite live helper contention"
    return
  fi
  if [[ ! -e "$marker" ]]; then
    fail "marker disappeared even though autoclean should have been blocked"
    return
  fi
  if ! grep -Fq -- "auto-clean blocked while repo-local gate helpers are still running" <<<"$output"; then
    fail "expected auto-clean block message; output: $output"
    return
  fi
  if ! grep -Fq -- "repo-local gate helpers still running:" <<<"$output"; then
    fail "expected live helper block; output: $output"
    return
  fi
  if ! grep -Fq -- "$sibling_pid" <<<"$output"; then
    fail "expected live helper pid in output; output: $output"
    return
  fi
  if ! grep -Fq -- "$marker" <<<"$output"; then
    fail "expected stale marker to remain listed after blocked autoclean; output: $output"
    return
  fi

  local final_block
  final_block="$(last_stale_block <<<"$output")"
  if grep -Fq -- "repo-local gate helpers still running:" <<<"$final_block"; then
    fail "repo-local gate helper leaked into stale pollution block: $final_block"
    return
  fi
  pass
}

# ---------------------------------------------------------------------------
# Scenario 36: swarm e2e worktree parser only reports branches created by the
# full-flow e2e harness. User/session worktrees under harness/* are preserved.
# ---------------------------------------------------------------------------
scenario_swarm_e2e_worktree_parser() {
  start_test "swarm e2e worktree parser filters e2e-owned branches"
  local fake_porcelain
  fake_porcelain=$'worktree /tmp/one\nHEAD 111\nbranch refs/heads/harness/sess-e2e-swarm-abc\n\nworktree /tmp/two\nHEAD 222\nbranch refs/heads/harness/msiap1rl\n\nworktree /tmp/three\nHEAD 333\nbranch refs/heads/harness/sess-e2e-swarm-def\n'
  local output
  output="$(stale_scan_swarm_e2e_worktrees_from_porcelain <<<"$fake_porcelain")"
  local ok=1
  assert_in_list $'/tmp/one\tharness/sess-e2e-swarm-abc' "swarm e2e worktree" "$output" || ok=0
  assert_in_list $'/tmp/three\tharness/sess-e2e-swarm-def' "swarm e2e worktree" "$output" || ok=0
  if grep -Fq -- "msiap1rl" <<<"$output"; then
    ok=0
    fail "non-e2e harness branch leaked into output: $output"
  fi
  if (( ok )); then pass; fi
}

# ---------------------------------------------------------------------------
# Scenario 37: clean-stale swarm cleanup must noop cleanly when no e2e-owned
# worktrees or branches are present. The production script runs under `set -u`,
# so empty arrays must be length-guarded before "${arr[@]}" iteration.
# ---------------------------------------------------------------------------
scenario_swarm_e2e_cleanup_empty_lists() {
  start_test "swarm e2e cleanup tolerates empty lists under nounset"
  local entries=()
  local entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && entries+=("$entry")
  done < <(stale_scan_swarm_e2e_worktrees_from_porcelain <<<"")

  local path branch
  if (( ${#entries[@]} > 0 )); then
    for entry in "${entries[@]}"; do
      path="${entry%%$'\t'*}"
      branch="${entry#*$'\t'}"
      [[ -n "$path" && -n "$branch" ]] || return 1
    done
  fi

  local branches=()
  while IFS= read -r branch; do
    [[ -n "$branch" ]] && branches+=("$branch")
  done < <(printf '')

  if (( ${#branches[@]} > 0 )); then
    for branch in "${branches[@]}"; do
      stale_scan_is_swarm_e2e_branch "$branch" || return 1
    done
  fi

  pass
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
  scenario_profile_scoped_tmp_artifacts_are_ignored
  scenario_profile_scoped_daemon_root
  scenario_lock_holding_build_process_not_orphaned
  scenario_lock_holder
  scenario_profiled_live_lock_holder_not_stale
  scenario_data_home_scoped_live_lock_holder_not_stale
  scenario_unscoped_live_lock_holder_still_stale
  scenario_clean_stale_safe_mode_preserves_live_shared_state
  scenario_clean_stale_full_reset_preserves_profiled_bridge_end_to_end
  scenario_pid_describe_format
  scenario_ancestor_exclusion
  scenario_common_root_gate_helper_detection
  scenario_profile_scoped_gate_helper_ignores_other_profiles
  scenario_congested_env
  scenario_end_to_end_detection
  scenario_clean_tmp_removal_is_idempotent
  scenario_installed_not_in_build_bucket
  scenario_refresh_updates_cache
  scenario_refresh_invalidates_ppid_map
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
  scenario_live_codex_app_server_listener_not_stale
  scenario_orphan_monitor_wrapper_detected
  scenario_monitor_wrapper_with_owner_metadata_not_flagged
  scenario_xcodebuild_lock_live_mutator_detected
  scenario_autoclean_success
  scenario_autoclean_unresolved_still_fails
  scenario_autoclean_clean_script_fails
  scenario_end_to_end_without_autoclean
  scenario_autoclean_congestion_partial
  scenario_autoclean_blocks_on_live_repo_gate_helpers
  scenario_swarm_e2e_worktree_parser
  scenario_swarm_e2e_cleanup_empty_lists
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
