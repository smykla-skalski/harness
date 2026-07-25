#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/version.sh"
OPENAPI_DOC="$ROOT/docs/api/openapi.json"

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

openapi_version() {
  perl -0ne 'print $1 if m{"info"\s*:\s*\{.*?"version"\s*:\s*"([^"]+)"}s' "$OPENAPI_DOC"
}

# `set` rewrites tracked files in place, so every scenario runs against the
# canonical version and restores the worktree afterwards. It also rewrites the
# generated Xcode project, which is untracked and therefore survives a
# checkout - re-sync it or the next `check` fails on this test's leftovers.
restore_versioned_files() {
  git -C "$ROOT" checkout -- \
    Cargo.toml Cargo.lock testkit/Cargo.toml aff/Cargo.toml \
    crates apps/harness-monitor docs/api/openapi.json 2>/dev/null || true
  if [[ -f "$ROOT/apps/harness-monitor/HarnessMonitor.xcodeproj/project.pbxproj" ]]; then
    "$SCRIPT" sync-monitor >/dev/null 2>&1 || true
  fi
}

scenario_set_stamps_the_openapi_document() {
  start_test "set stamps the openapi document alongside the other surfaces"
  local original bumped stamped
  original="$("$SCRIPT" show)"
  bumped="$(perl -e '
    my ($major, $minor, $patch) = split /\./, $ARGV[0];
    print join ".", $major, $minor, $patch + 1;
  ' "$original")"

  if ! "$SCRIPT" set "$bumped" >/dev/null 2>&1; then
    fail "version.sh set $bumped exited non-zero"
    restore_versioned_files
    return 1
  fi

  stamped="$(openapi_version)"
  if [[ "$stamped" == "$bumped" ]]; then
    pass
  else
    fail "openapi document reports $stamped after setting $bumped"
  fi
  restore_versioned_files
}

scenario_check_rejects_a_stale_openapi_document() {
  start_test "check fails when only the openapi document is stale"
  perl -0pi -e 's{("info"\s*:\s*\{.*?"version"\s*:\s*")[^"]+(")}{${1}0.0.0${2}}s' "$OPENAPI_DOC"

  if "$SCRIPT" check >/dev/null 2>&1; then
    fail "check passed with a stale openapi version"
  else
    pass
  fi
  restore_versioned_files
}

trap restore_versioned_files EXIT

scenario_set_stamps_the_openapi_document
scenario_check_rejects_a_stale_openapi_document

log "version tests: $PASS_COUNT passed, $FAIL_COUNT failed"
if ((FAIL_COUNT > 0)); then
  exit 1
fi
