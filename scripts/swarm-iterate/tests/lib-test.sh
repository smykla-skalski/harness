#!/usr/bin/env bash
# Shared helpers for swarm-iterate shell tests. Sourced, never run directly.
# Mirrors scripts/e2e/recording-triage/tests/lib-test.sh.

# shellcheck shell=bash

swarm_iterate_test_repo_root() {
  local script_dir
  script_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  CDPATH='' cd -- "$script_dir/../../.." && pwd
}

swarm_iterate_test_make_run_dir() {
  local prefix="$1"
  mktemp -d -t "swarm-iterate-${prefix}.XXXXXX"
}

# Writes a minimal valid active.md fixture into <run_dir>/active.md and an
# empty-table ledger.md into <run_dir>/ledger.md. Echoes the run_dir path.
swarm_iterate_test_seed_pair() {
  local run_dir="$1"
  cat >"$run_dir/active.md" <<'EOF'
# Swarm e2e active findings

- Iteration: 7
- Last run slug: 260101010101-test-run-slug
- Last status: 16/16 acks; manifest passed
- Last terminated at: 2026-01-01T01:01:01Z

| ID | Status | Severity | Subsystem | Iteration found | Iteration closed | Recording timestamps | Current behavior | Desired behavior | Evidence | Fix commit |
|----|--------|----------|-----------|-----------------|------------------|----------------------|------------------|------------------|----------|------------|
| L-9001 | Open | medium | sample-sub | 5 | - | 00:00-00:10 (launch 1) | bug bug bug | fix fix fix | recording.mov | - |
EOF

  cat >"$run_dir/ledger.md" <<'EOF'
# Swarm e2e ledger (closed findings archive)

Append-only. Rows arrive from active.md after the Move Protocol.

| ID | Status | Severity | Subsystem | Iteration found | Iteration closed | Recording timestamps | Current behavior | Desired behavior | Evidence | Fix commit |
|----|--------|----------|-----------|-----------------|------------------|----------------------|------------------|------------------|----------|------------|
EOF
}

# Exports SWARM_ITERATE_ACTIVE_PATH / _LEDGER_PATH so the helpers under test
# read the fixture files.
swarm_iterate_test_export_paths() {
  local run_dir="$1"
  export SWARM_ITERATE_ACTIVE_PATH="$run_dir/active.md"
  export SWARM_ITERATE_LEDGER_PATH="$run_dir/ledger.md"
}

# Counts how many times an ID appears in a file. Echoes integer.
swarm_iterate_test_count_id() {
  local file="$1"
  local id="$2"
  awk -v id="$id" -F'|' '
    {
      tmp = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", tmp)
      if (tmp == id) count++
    }
    END { print (count ? count : 0) }
  ' "$file"
}

# Runs a command, captures status, prints it on a labelled line.
swarm_iterate_test_run_capture() {
  local label="$1"
  shift
  local status=0
  "$@" >/dev/null 2>&1 || status=$?
  printf '%s status=%s\n' "$label" "$status"
}
