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
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  [[ -n "$TEST_TMP_ROOT" ]] && rm -rf "$TEST_TMP_ROOT"
}
trap cleanup EXIT

reset_tmp_root() {
  [[ -n "$TEST_TMP_ROOT" ]] && rm -rf "$TEST_TMP_ROOT"
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clean-build-caches-test.XXXXXX")"
}

assert_output_contains() {
  local haystack="$1"
  local needle="$2"
  grep -Fq -- "$needle" <<<"$haystack" || {
    fail "expected output to contain: $needle"
    return 1
  }
}

# Builds a fixture repo whose target/ mirrors the shared cargo-local.sh
# layout: target/dev/agent-live (a genuinely running background process
# holds its lease), target/dev/agent-dead (lease PID has already exited),
# target/dev/agent-nolease (no lease file at all), a stray top-level entry
# directly under target/ that predates the per-agent scheme, and a stray
# file directly under target/dev/ (not a segment directory).
make_shared_target_fixture() {
  local repo="$1"
  mkdir -p "$repo/scripts/lib"
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
  sleep 60 &
  live_pid=$!
  LIVE_LEASE_PIDS+=("$live_pid")
  printf '%s\n' "$live_pid" > "$repo/target/.cargo-local/leases/live-$live_pid"

  local dead_pid
  (exit 0) &
  dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  printf '%s\n' "$dead_pid" > "$repo/target/.cargo-local/leases/dead-$dead_pid"
}

scenario_dry_run_keeps_leased_segment() {
  start_test "dry-run keeps a segment with a live cargo-local.sh lease"
  reset_tmp_root
  local repo="$TEST_TMP_ROOT/repo"
  local output=""

  make_shared_target_fixture "$repo"
  output="$(cd "$repo" && ./scripts/clean-build-caches.sh --dry-run)"

  assert_output_contains "$output" "target/dev/agent-live"
  assert_output_contains "$output" "(active build, kept)"
  assert_output_contains "$output" "target/dev/agent-dead"
  assert_output_contains "$output" "target/dev/agent-nolease"
  assert_output_contains "$output" "target/stray-legacy-artifact"
  assert_output_contains "$output" "target/dev/.rustc_info.json"
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
scenario_includes_daemon_cargo_target
scenario_includes_all_repo_rust_target_roots
scenario_includes_all_project_xcode_roots
scenario_includes_swiftpm_build_roots
scenario_includes_scope_comment

log "clean-build-caches tests: $PASS_COUNT passed, $FAIL_COUNT failed"
if (( FAIL_COUNT > 0 )); then
  exit 1
fi
