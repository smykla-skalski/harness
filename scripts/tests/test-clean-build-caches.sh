#!/usr/bin/env bash
# Static coverage for clean-build-caches.sh targets that are easy to miss
# because they live in ignored repo-local build roots.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/clean-build-caches.sh"

PASS_COUNT=0
FAIL_COUNT=0
CURRENT_TEST=""

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

scenario_includes_daemon_cargo_target
scenario_includes_all_repo_rust_target_roots
scenario_includes_all_project_xcode_roots
scenario_includes_swiftpm_build_roots
scenario_includes_scope_comment

log "clean-build-caches tests: $PASS_COUNT passed, $FAIL_COUNT failed"
if (( FAIL_COUNT > 0 )); then
  exit 1
fi
