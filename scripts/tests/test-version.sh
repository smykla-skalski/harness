#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SANDBOX=""
SCRIPT=""
OPENAPI_DOC=""

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

skip() {
  log "  SKIP: $CURRENT_TEST - $*"
}

start_test() {
  CURRENT_TEST="$1"
  log "TEST: $CURRENT_TEST"
}

discard_sandbox() {
  if [[ -n "$SANDBOX" ]]; then
    rm -rf "$SANDBOX"
    SANDBOX=""
  fi
}

trap discard_sandbox EXIT

# `version.sh` rewrites every version surface in place, and it resolves its own
# root from `$0`. Seeding a copy under a sandbox therefore keeps the whole run
# off the real worktree, including any uncommitted edits sitting in it.
seed_sandbox() {
  local source target
  discard_sandbox
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/version-test.XXXXXX")"
  # The generated Xcode project is deliberately absent: `version.sh` skips it
  # when it does not exist, which keeps this suite off the one surface a
  # checkout cannot restore.
  local sources=(
    "$ROOT/scripts/version.sh"
    "$ROOT/apps/harness-monitor/Scripts/lib/swift-tool-env.sh"
    "$ROOT/apps/harness-monitor/Scripts/lib/xcode-version.sh"
    "$ROOT/apps/harness-monitor/Scripts/patch-tuist-pbxproj.py"
    "$ROOT/apps/harness-monitor/Tuist/ProjectDescriptionHelpers/BuildSettings.swift"
    "$ROOT/apps/harness-monitor/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist"
    "$ROOT/Cargo.toml"
    "$ROOT/Cargo.lock"
    "$ROOT/testkit/Cargo.toml"
    "$ROOT/aff/Cargo.toml"
    "$ROOT/docs/api/openapi.json"
    "$ROOT/src/observe/output.rs"
    "$ROOT"/crates/*/Cargo.toml
  )
  for source in "${sources[@]}"; do
    target="$SANDBOX/${source#"$ROOT/"}"
    mkdir -p -- "$(dirname -- "$target")"
    cp -R -- "$source" "$target"
  done
  SCRIPT="$SANDBOX/scripts/version.sh"
  OPENAPI_DOC="$SANDBOX/docs/api/openapi.json"
}

# Parsed, not matched: the document has several `version` keys, and reading it
# by pattern could report a schema property when `info` is the field at stake.
openapi_version() {
  python3 - "$OPENAPI_DOC" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["info"]["version"], end="")
PY
}

# Sets the field outright so the scenario below cannot pass because the edit
# quietly missed. Formatting is irrelevant here; only the version is read back.
stale_the_openapi_document() {
  python3 - "$OPENAPI_DOC" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
document["info"]["version"] = "0.0.0"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle)
PY
}

# Without this, a sandbox that is already out of sync would make every
# "check fails" assertion below pass for the wrong reason.
scenario_seeded_sandbox_starts_in_sync() {
  seed_sandbox
  start_test "a freshly seeded sandbox passes check"
  if "$SCRIPT" check >/dev/null 2>&1; then
    pass
  else
    fail "check failed before any scenario touched the sandbox"
  fi
}

scenario_check_rejects_a_stale_openapi_document() {
  seed_sandbox
  start_test "check fails when only the openapi document is stale"
  stale_the_openapi_document

  if "$SCRIPT" check >/dev/null 2>&1; then
    fail "check passed with a stale openapi version"
  else
    pass
  fi
}

scenario_check_names_an_unreadable_openapi_version() {
  seed_sandbox
  start_test "check names an unreadable openapi version rather than a mismatch"
  local output
  printf '{}' >"$OPENAPI_DOC"

  output="$("$SCRIPT" check 2>&1 || true)"
  if [[ "$output" == *"<unreadable info.version>"* ]]; then
    pass
  else
    fail "check blamed a version it could not read: $output"
  fi
}

scenario_set_stamps_the_openapi_document() {
  seed_sandbox
  start_test "set stamps the openapi document alongside the other surfaces"
  local original bumped stamped
  # `set` reaches PlistBuddy through sync_monitor, so the write path is
  # macOS-only even though `check` runs everywhere.
  if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "version.sh set needs PlistBuddy"
    return 0
  fi
  original="$("$SCRIPT" show)"
  bumped="$(perl -e '
    my ($major, $minor, $patch) = split /\./, $ARGV[0];
    print join ".", $major, $minor, $patch + 1;
  ' "$original")"

  if ! "$SCRIPT" set "$bumped" >/dev/null 2>&1; then
    fail "version.sh set $bumped exited non-zero"
    return 1
  fi

  stamped="$(openapi_version)"
  if [[ "$stamped" == "$bumped" ]]; then
    pass
  else
    fail "openapi document reports $stamped after setting $bumped"
  fi
}

scenario_seeded_sandbox_starts_in_sync
scenario_check_rejects_a_stale_openapi_document
scenario_check_names_an_unreadable_openapi_version
scenario_set_stamps_the_openapi_document

log "version tests: $PASS_COUNT passed, $FAIL_COUNT failed"
if ((FAIL_COUNT > 0)); then
  exit 1
fi
