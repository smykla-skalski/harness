#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/swarm-iterate/tests/lib-test.sh
. "$SCRIPT_DIR/lib-test.sh"

REPO_ROOT="$(swarm_iterate_test_repo_root)"
CLOSE="$REPO_ROOT/scripts/swarm-iterate/close-finding.sh"

run_dir="$(swarm_iterate_test_make_run_dir close)"
trap 'rm -rf "$run_dir"' EXIT

swarm_iterate_test_seed_pair "$run_dir"
swarm_iterate_test_export_paths "$run_dir"

# Happy path: the seeded active.md has L-9001 Open. Close it.
"$CLOSE" L-9001 abcdef0 >"$run_dir/close.log"

active_count="$(swarm_iterate_test_count_id "$run_dir/active.md" L-9001)"
ledger_count="$(swarm_iterate_test_count_id "$run_dir/ledger.md" L-9001)"
if [[ "$active_count" != "0" ]]; then
  printf 'expected L-9001 absent from active.md, found %s occurrence(s)\n' "$active_count" >&2
  exit 1
fi
if [[ "$ledger_count" != "1" ]]; then
  printf 'expected L-9001 once in ledger.md, found %s occurrence(s)\n' "$ledger_count" >&2
  exit 1
fi

# Verify the appended row carries Closed + iteration 7 + sha abcdef0.
appended="$(grep -F '| L-9001 |' "$run_dir/ledger.md")"
case "$appended" in
  *' Closed '*) ;;
  *) printf 'expected appended row to carry Status=Closed, got: %s\n' "$appended" >&2; exit 1 ;;
esac
case "$appended" in
  *' 7 '*) ;;
  *) printf 'expected appended row to carry Iteration closed=7, got: %s\n' "$appended" >&2; exit 1 ;;
esac
case "$appended" in
  *' abcdef0 '*) ;;
  *) printf 'expected appended row to carry Fix commit=abcdef0, got: %s\n' "$appended" >&2; exit 1 ;;
esac

# Re-run on the same id should fail (row no longer in active.md).
status=0
"$CLOSE" L-9001 abcdef0 >/dev/null 2>&1 || status=$?
if [[ "$status" == "0" ]]; then
  printf 'expected close-finding.sh to fail when row already moved\n' >&2
  exit 1
fi

# Bad id format must reject without touching files.
status=0
"$CLOSE" L-99 abcdef0 >/dev/null 2>&1 || status=$?
if [[ "$status" == "0" ]]; then
  printf 'expected close-finding.sh to reject malformed id\n' >&2
  exit 1
fi

# Bad sha format must reject.
status=0
"$CLOSE" L-9002 NOTHEX >/dev/null 2>&1 || status=$?
if [[ "$status" == "0" ]]; then
  printf 'expected close-finding.sh to reject non-hex sha\n' >&2
  exit 1
fi

# Pre-condition: row missing in active.md surfaces a non-zero exit.
status=0
"$CLOSE" L-9999 abcdef0 >/dev/null 2>&1 || status=$?
if [[ "$status" == "0" ]]; then
  printf 'expected close-finding.sh to fail when id absent\n' >&2
  exit 1
fi

printf 'close-finding test ok\n'
