#!/usr/bin/env bash
# Static coverage for clean-build-caches.sh targets that are easy to miss
# because they live in ignored repo-local build roots.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/clean-build-caches.sh"

PASS_COUNT=0
FAIL_COUNT=0
CURRENT_TEST=""
TEST_TMP_ROOT=""
LIVE_LEASE_PIDS=()

log() {
  printf '%s\n' "$*" >&2
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  log "  FAIL: $CURRENT_TEST - $*"
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  log "  PASS: $CURRENT_TEST"
}

start_test() {
  CURRENT_TEST="$1"
  log "TEST: $CURRENT_TEST"
}

assert_contains() {
  local needle="$1"
  if grep -Fq -- "$needle" "$SCRIPT"; then
    return 0
  fi
  fail "expected clean-build-caches.sh to contain: $needle"
  return 1
}

cleanup() {
  local pid
  for pid in "${LIVE_LEASE_PIDS[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  [[ -n "$TEST_TMP_ROOT" ]] && rm -rf "$TEST_TMP_ROOT"
}
trap cleanup EXIT

reset_tmp_root() {
  [[ -n "$TEST_TMP_ROOT" ]] && rm -rf "$TEST_TMP_ROOT"
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clean-build-caches-test.XXXXXX")"
}

assert_output_line_contains() {
  local haystack="$1" path_needle="$2" marker="$3" line
  line="$(grep -F -- "$path_needle" <<<"$haystack")" || {
    fail "expected output to contain a line for: $path_needle"
    return 1
  }
  grep -Fq -- "$marker" <<<"$line" || {
    fail "expected line for $path_needle to contain '$marker', got: $line"
    return 1
  }
}

# kill -0 fails both when a PID is gone and when it belongs to another user
# we can't signal, so a live foreign-owned PID would look unused. ps -p
# reports existence without needing signal permission.
pid_exists() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null && return 0
  ps -p "$pid" >/dev/null 2>&1
}

# A PID no process holds, found by probing upward from a value past any
# realistic pid_max rather than spawning and reaping a real process, since
# a just-freed PID can be reassigned before the lease file is read. Starts
# above the kernel's configured pid_max where that's exposed (Linux), since
# a raised pid_max can otherwise put 999999 inside the live range.
unused_pid() {
  local candidate=999999 pid_max
  if [[ -r /proc/sys/kernel/pid_max ]]; then
    pid_max="$(cat /proc/sys/kernel/pid_max 2>/dev/null || true)"
    if [[ "$pid_max" =~ ^[0-9]+$ ]] && (( pid_max >= candidate )); then
      candidate=$((pid_max + 1))
    fi
  fi
  while pid_exists "$candidate"; do
    candidate=$((candidate + 1))
  done
  printf '%s\n' "$candidate"
}

# Builds a fixture repo whose target/ mirrors the shared cargo-local.sh
# layout: target/dev/agent-live (a genuinely running background process
# holds its lease), target/dev/agent-dead (lease PID has already exited),
# target/dev/agent-nolease (no lease file at all), a stray top-level entry
# directly under target/ that predates the per-agent scheme, a stray file
# directly under target/dev/ (not a segment directory), and an empty
# fake-home/ the caller can point HOME at so the script's global-cache
# section doesn't size the real $HOME/Library/Caches/*.
make_shared_target_fixture() {
  local repo="$1"
  mkdir -p "$repo/scripts/lib"
  mkdir -p "$repo/fake-home"
  cp "$SCRIPT" "$repo/scripts/clean-build-caches.sh"
  cp "$ROOT/scripts/lib/common-repo-root.sh" "$repo/scripts/lib/common-repo-root.sh"

  mkdir -p "$repo/target/dev/agent-live/debug"
  mkdir -p "$repo/target/dev/agent-dead/debug"
  mkdir -p "$repo/target/dev/agent-nolease/debug"
  echo "obj" > "$repo/target/dev/agent-live/debug/harness"
  echo "obj" > "$repo/target/dev/agent-dead/debug/harness"
  echo "obj" > "$repo/target/dev/agent-nolease/debug/harness"
  echo "stray" > "$repo/target/stray-legacy-artifact"
  echo "stray" > "$repo/target/dev/.rustc_info.json"

  mkdir -p "$repo/target/.cargo-local/leases"
  local live_pid
  sleep 300 &
  live_pid=$!
  LIVE_LEASE_PIDS+=("$live_pid")
  printf '%s\n' "$live_pid" > "$repo/target/.cargo-local/leases/live-$live_pid"

  local dead_pid
  dead_pid="$(unused_pid)"
  printf '%s\n' "$dead_pid" > "$repo/target/.cargo-local/leases/dead-$dead_pid"
}

scenario_dry_run_keeps_leased_segment() {
  start_test "dry-run keeps a segment with a live cargo-local.sh lease"
  reset_tmp_root
  local repo="$TEST_TMP_ROOT/repo"
  local output=""

  make_shared_target_fixture "$repo"
  output="$(cd "$repo" && HOME="$repo/fake-home" ./scripts/clean-build-caches.sh --dry-run)"

  assert_output_line_contains "$output" "target/dev/agent-live" "(active build, kept)"
  assert_output_line_contains "$output" "target/dev/agent-dead" "(dry-run)"
  assert_output_line_contains "$output" "target/dev/agent-nolease" "(dry-run)"
  assert_output_line_contains "$output" "target/stray-legacy-artifact" "(dry-run)"
  assert_output_line_contains "$output" "target/dev/.rustc_info.json" "(dry-run)"
  pass
}

scenario_missing_common_repo_root_lib_aborts_safely() {
  start_test "missing common-repo-root.sh aborts instead of computing a wrong path"
  reset_tmp_root
  local repo="$TEST_TMP_ROOT/repo"
  local output="" status=0

  make_shared_target_fixture "$repo"
  rm -f "$repo/scripts/lib/common-repo-root.sh"

  output="$(cd "$repo" && HOME="$repo/fake-home" ./scripts/clean-build-caches.sh --dry-run 2>&1)" || status=$?

  if (( status == 0 )); then
    fail "expected a nonzero exit when common-repo-root.sh is missing, got 0"
    return
  fi
  grep -Fq "failed to source scripts/lib/common-repo-root.sh" <<<"$output" || {
    fail "expected the failure message in output, got: $output"
    return
  }
  if grep -Fq "== clean-build-caches ==" <<<"$output"; then
    fail "expected the script to abort before printing its normal banner"
    return
  fi
  pass
}

scenario_includes_daemon_cargo_target() {
  start_test "daemon cargo target is a clean:caches target"
  assert_contains "remove_path 'daemon cargo target'" || return
  assert_contains "\"\$ROOT/.cache/harness-monitor-xcode-daemon\"" || return
  pass
}

scenario_includes_all_repo_rust_target_roots() {
  start_test "repo Rust target search includes apps, crates, and mcp-servers"
  assert_contains "\"\$ROOT/apps\" \"\$ROOT/crates\" \"\$ROOT/mcp-servers\"" || return
  assert_contains "-type d -name target -prune -print0" || return
  pass
}

scenario_includes_all_project_xcode_roots() {
  start_test "project-local Xcode derived roots are explicit targets"
  assert_contains "remove_path 'xcode-derived/'" || return
  assert_contains "remove_path 'xcode-derived-e2e/'" || return
  assert_contains "remove_path 'xcode-derived-lanes/'" || return
  assert_contains "remove_path 'xcode-derived-instruments/'" || return
  pass
}

scenario_includes_swiftpm_build_roots() {
  start_test "SwiftPM .build search covers apps and mcp-servers"
  assert_contains "section 'SwiftPM artifacts (project-local)'" || return
  assert_contains "\"\$ROOT/apps\" \"\$ROOT/mcp-servers\"" || return
  assert_contains "-type d -name '.build' -prune -print0" || return
  pass
}

scenario_includes_scope_comment() {
  start_test "default scope documents the ignored build roots"
  assert_contains ".cache/harness-monitor-xcode-daemon" || return
  assert_contains "Repo SwiftPM artifacts" || return
  pass
}

scenario_dry_run_keeps_leased_segment
scenario_missing_common_repo_root_lib_aborts_safely
scenario_includes_daemon_cargo_target
scenario_includes_all_repo_rust_target_roots
scenario_includes_all_project_xcode_roots
scenario_includes_swiftpm_build_roots
scenario_includes_scope_comment

log "clean-build-caches tests: $PASS_COUNT passed, $FAIL_COUNT failed"
if (( FAIL_COUNT > 0 )); then
  exit 1
fi
