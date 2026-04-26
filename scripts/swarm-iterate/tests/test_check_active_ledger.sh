#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/swarm-iterate/tests/lib-test.sh
. "$SCRIPT_DIR/lib-test.sh"

REPO_ROOT="$(swarm_iterate_test_repo_root)"
CHECK="$REPO_ROOT/scripts/swarm-iterate/check-active-ledger.sh"

run_dir="$(swarm_iterate_test_make_run_dir check)"
trap 'rm -rf "$run_dir"' EXIT

swarm_iterate_test_seed_pair "$run_dir"
swarm_iterate_test_export_paths "$run_dir"

# Happy path: clean fixture passes.
status=0
"$CHECK" >/dev/null 2>&1 || status=$?
if [[ "$status" != "0" ]]; then
  printf 'expected clean fixture to pass, got status=%s\n' "$status" >&2
  exit 1
fi

# Cross-file collision: same ID in both files.
swarm_iterate_test_seed_pair "$run_dir"
cat >>"$run_dir/ledger.md" <<'EOF'
| L-9001 | Closed | medium | sample-sub | 5 | 5 | 00:00-00:10 (launch 1) | bug | fix | recording.mov | abcdef0 |
EOF
status=0
"$CHECK" >/dev/null 2>&1 || status=$?
if [[ "$status" == "0" ]]; then
  printf 'expected check-active-ledger.sh to fail on cross-file collision\n' >&2
  exit 1
fi

# Bad Status in active.md: row marked Closed but still in active.md.
swarm_iterate_test_seed_pair "$run_dir"
sed -i.bak 's/| L-9001 | Open /| L-9001 | Closed /' "$run_dir/active.md"
rm -f "$run_dir/active.md.bak"
status=0
"$CHECK" >/dev/null 2>&1 || status=$?
if [[ "$status" == "0" ]]; then
  printf 'expected check-active-ledger.sh to fail on Closed row in active.md\n' >&2
  exit 1
fi

# Bad Status in ledger.md: row marked Open landed in archive.
swarm_iterate_test_seed_pair "$run_dir"
cat >>"$run_dir/ledger.md" <<'EOF'
| L-9002 | Open | low | sample-sub | 5 | 5 | n/a (no recording) | bug | fix | log | abcdef1 |
EOF
status=0
"$CHECK" >/dev/null 2>&1 || status=$?
if [[ "$status" == "0" ]]; then
  printf 'expected check-active-ledger.sh to fail on Open row in ledger.md\n' >&2
  exit 1
fi

# Duplicate IDs within the same file.
swarm_iterate_test_seed_pair "$run_dir"
cat >>"$run_dir/active.md" <<'EOF'
| L-9001 | Open | medium | sample-sub | 5 | - | 00:00-00:10 (launch 1) | bug | fix | recording.mov | - |
EOF
status=0
"$CHECK" >/dev/null 2>&1 || status=$?
if [[ "$status" == "0" ]]; then
  printf 'expected check-active-ledger.sh to fail on duplicate IDs in active.md\n' >&2
  exit 1
fi

# Missing header keys.
swarm_iterate_test_seed_pair "$run_dir"
sed -i.bak '/^- Iteration: /d' "$run_dir/active.md"
rm -f "$run_dir/active.md.bak"
status=0
"$CHECK" >/dev/null 2>&1 || status=$?
if [[ "$status" == "0" ]]; then
  printf 'expected check-active-ledger.sh to fail when header key missing\n' >&2
  exit 1
fi

# Missing canonical column header line.
swarm_iterate_test_seed_pair "$run_dir"
sed -i.bak '/^| ID | Status |/d' "$run_dir/ledger.md"
rm -f "$run_dir/ledger.md.bak"
status=0
"$CHECK" >/dev/null 2>&1 || status=$?
if [[ "$status" == "0" ]]; then
  printf 'expected check-active-ledger.sh to fail when ledger missing column header\n' >&2
  exit 1
fi

# Both files absent: expected to pass silently (clean repo).
rm -f "$run_dir/active.md" "$run_dir/ledger.md"
status=0
"$CHECK" >/dev/null 2>&1 || status=$?
if [[ "$status" != "0" ]]; then
  printf 'expected check-active-ledger.sh to pass when both files absent, got status=%s\n' "$status" >&2
  exit 1
fi

# Asymmetric absence: only ledger present must fail.
swarm_iterate_test_seed_pair "$run_dir"
rm -f "$run_dir/active.md"
status=0
"$CHECK" >/dev/null 2>&1 || status=$?
if [[ "$status" == "0" ]]; then
  printf 'expected check-active-ledger.sh to fail when only ledger.md exists\n' >&2
  exit 1
fi

printf 'check-active-ledger test ok\n'
