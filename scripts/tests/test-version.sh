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
    "$ROOT"/tools/*/Cargo.toml
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

canonical_version() {
  "$SCRIPT" show
}

next_patch_version() {
  perl -e '
    my ($major, $minor, $patch) = split /\./, $ARGV[0];
    print join ".", $major, $minor, $patch + 1;
  ' "$(canonical_version)"
}

# Parsed here rather than asked of version.sh, so a scenario cannot pass
# because the reader under test and the assertion share the same blind spot.
sandbox_member_versions() {
  python3 - "$SANDBOX" <<'PY'
import os
import re
import sys

root = sys.argv[1]
manifest = open(os.path.join(root, "Cargo.toml"), encoding="utf-8").read()
lock = open(os.path.join(root, "Cargo.lock"), encoding="utf-8").read()
members = re.search(r"^members\s*=\s*\[(.*?)\]", manifest, re.M | re.S).group(1)

for member in re.findall(r'"([^"]+)"', members):
    text = open(os.path.join(root, member, "Cargo.toml"), encoding="utf-8").read()
    package = re.search(r'\[package\]\s*name = "([^"]+)"\s*version = "([^"]+)"', text)
    entry = re.search(
        r'\[\[package\]\]\s*name = "%s"\s*version = "([^"]+)"' % re.escape(package.group(1)),
        lock,
    )
    print(f"{package.group(1)}\t{package.group(2)}\t{entry.group(1) if entry else '<missing>'}")
PY
}

stale_member_package_version() {
  local member="$1"
  perl -0pi -e '
    my $count = s/(\[package\]\s*name = "[^"]+"\s*version = ")[^"]+(")/${1}0.0.1$2/s;
    die "failed to stale the package version in $ARGV\n" unless $count;
  ' "$SANDBOX/$member/Cargo.toml"
}

set_member_package_version() {
  local member="$1"
  NEW_VERSION="$2" perl -0pi -e '
    my $count = s/(\[package\]\s*name = "[^"]+"\s*version = ")[^"]+(")/$1.$ENV{NEW_VERSION}.$2/se;
    die "failed to set the package version in $ARGV\n" unless $count;
  ' "$SANDBOX/$member/Cargo.toml"
}

set_lock_package_version() {
  PACKAGE_NAME="$1" NEW_VERSION="$2" perl -0pi -e '
    my $count = s/(\[\[package\]\]\s*name = "\Q$ENV{PACKAGE_NAME}\E"\s*version = ")[^"]+(")/$1.$ENV{NEW_VERSION}.$2/se;
    die "failed to set the lock version for $ENV{PACKAGE_NAME}\n" unless $count;
  ' "$SANDBOX/Cargo.lock"
}

# The exemption is read back out of the script rather than repeated here, so a
# crate joining or leaving the list cannot leave this suite asserting the old
# set. The scenarios that name `harness-panel` state intended behaviour and are
# meant to be read literally.
independent_package_names() {
  perl -0ne '
    unless (/^INDEPENDENT_PACKAGE_NAMES=\((.*?)\)/ms) {
      die "failed to read INDEPENDENT_PACKAGE_NAMES from $ARGV\n";
    }
    my $names = $1;
    print "$1\n" while $names =~ /"([^"]+)"/g;
  ' "$SCRIPT"
}

check_rejects() {
  local needle="$1"
  local output
  if output="$("$SCRIPT" check 2>&1)"; then
    fail "check passed; expected it to name $needle"
    return 0
  fi
  if [[ "$output" == *"$needle"* ]]; then
    pass
  else
    fail "check failed without naming $needle: $output"
  fi
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
  local bumped stamped
  # `set` reaches PlistBuddy through sync_monitor, so the write path is
  # macOS-only even though `check` runs everywhere.
  if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "version.sh set needs PlistBuddy"
    return 0
  fi
  bumped="$(next_patch_version)"

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

scenario_check_rejects_a_stale_member_crate() {
  seed_sandbox
  start_test "check fails when a workspace member keeps the old version"
  stale_member_package_version "crates/harness-kernel"

  check_rejects "harness-kernel"
}

scenario_check_rejects_a_member_added_after_the_tooling() {
  seed_sandbox
  start_test "check fails for a member added after the version tooling was last touched"
  mkdir -p "$SANDBOX/crates/harness-late-arrival"
  cat >"$SANDBOX/crates/harness-late-arrival/Cargo.toml" <<'EOF'
[package]
name = "harness-late-arrival"
version = "0.0.1"
edition = "2024"
rust-version = "1.95"
publish = false

[dependencies]
EOF
  perl -0pi -e '
    my $count = s{^(members\s*=\s*\[)}{$1\n  "crates/harness-late-arrival",}m;
    die "failed to add the member in $ARGV\n" unless $count;
  ' "$SANDBOX/Cargo.toml"

  check_rejects "harness-late-arrival"
}

scenario_check_rejects_a_stale_member_requirement() {
  seed_sandbox
  start_test "check fails when a member's requirement on another member is stale"
  perl -pi -e '
    if (s/^(harness-kernel\s*=\s*\{[^}]*\bversion\s*=\s*")[^"]+(")/${1}0.0.1$2/) {
      $ENV{STALED} = 1;
    }
    END { die "failed to stale the requirement\n" unless $ENV{STALED}; }
  ' "$SANDBOX/crates/harness-workspace/Cargo.toml"

  check_rejects "harness-kernel"
}

# A requirement version.sh cannot rewrite has to be reported, not skipped:
# skipping is exactly how the fixed crate list lost crates without anyone
# noticing. The version here is the canonical one, so the scenario proves the
# shape is refused rather than catching an ordinary mismatch.
scenario_check_rejects_an_unreadable_member_requirement() {
  seed_sandbox
  start_test "check fails on a member requirement it cannot rewrite in place"
  local manifest="$SANDBOX/crates/harness-workspace/Cargo.toml"
  perl -ni -e 'print unless /^harness-kernel\s*=/' "$manifest"
  cat >>"$manifest" <<EOF

[dependencies.harness-kernel]
path = "../harness-kernel"
version = "$(canonical_version)"
EOF

  check_rejects "harness-kernel"
}

scenario_set_moves_every_shared_workspace_member() {
  seed_sandbox
  start_test "set moves every workspace member that shares the root version"
  local bumped exempt stragglers
  if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "version.sh set needs PlistBuddy"
    return 0
  fi
  bumped="$(next_patch_version)"
  exempt=" $(independent_package_names | tr '\n' ' ')"

  if ! "$SCRIPT" set "$bumped" >/dev/null 2>&1; then
    fail "version.sh set $bumped exited non-zero"
    return 1
  fi

  stragglers="$(sandbox_member_versions | awk -v want="$bumped" -v exempt="$exempt" '
    index(exempt, " " $1 " ") { next }
    $2 != want { print $1 " manifest " $2 }
    $3 != want { print $1 " lock " $3 }
  ')"
  if [[ -z "$stragglers" ]]; then
    pass
  else
    fail "members left behind by set $bumped: $(printf '%s' "$stragglers" | tr '\n' ' ')"
  fi
}

scenario_check_ignores_an_independent_member_version() {
  seed_sandbox
  start_test "check passes when an independent member carries its own version"
  set_member_package_version "crates/harness-panel" "9.9.9"
  set_lock_package_version "harness-panel" "9.9.9"

  if "$SCRIPT" check >/dev/null 2>&1; then
    pass
  else
    fail "check flagged an independent member: $("$SCRIPT" check 2>&1)"
  fi
}

# Exempt from the root version, not from being consistent with itself: a lock
# entry that disagrees with the crate's own manifest is still a broken tree.
scenario_check_rejects_an_independent_member_lock_drift() {
  seed_sandbox
  start_test "check fails when an independent member's lock entry lags its manifest"
  set_member_package_version "crates/harness-panel" "9.9.9"

  check_rejects "harness-panel"
}

scenario_set_leaves_an_independent_member_alone() {
  seed_sandbox
  start_test "set leaves an independent member and its lock entry alone"
  local bumped after
  if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "version.sh set needs PlistBuddy"
    return 0
  fi
  set_member_package_version "crates/harness-panel" "9.9.9"
  set_lock_package_version "harness-panel" "9.9.9"
  bumped="$(next_patch_version)"

  if ! "$SCRIPT" set "$bumped" >/dev/null 2>&1; then
    fail "version.sh set $bumped exited non-zero"
    return 1
  fi

  after="$(sandbox_member_versions | awk '$1 == "harness-panel" { print $2 " " $3 }')"
  if [[ "$after" == "9.9.9 9.9.9" ]]; then
    pass
  else
    fail "harness-panel reports $after after setting $bumped"
  fi
}

scenario_seeded_sandbox_starts_in_sync
scenario_check_rejects_a_stale_openapi_document
scenario_check_names_an_unreadable_openapi_version
scenario_set_stamps_the_openapi_document
scenario_check_rejects_a_stale_member_crate
scenario_check_rejects_a_member_added_after_the_tooling
scenario_check_rejects_a_stale_member_requirement
scenario_check_rejects_an_unreadable_member_requirement
scenario_set_moves_every_shared_workspace_member
scenario_check_ignores_an_independent_member_version
scenario_check_rejects_an_independent_member_lock_drift
scenario_set_leaves_an_independent_member_alone

log "version tests: $PASS_COUNT passed, $FAIL_COUNT failed"
if ((FAIL_COUNT > 0)); then
  exit 1
fi
