#!/usr/bin/env bash
# Shared helpers for the swarm-e2e-iterate ledger system.
# Sourced by close-finding.sh, check-active-ledger.sh, and the test suite.

# shellcheck shell=bash
# shellcheck source=scripts/e2e/lib.sh
. "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/e2e/lib.sh"

# Default file paths under <repo>/_artifacts. Tests override via env vars
# so they can target a fixture tree instead of the live working state.
swarm_iterate_active_path() {
  if [[ -n "${SWARM_ITERATE_ACTIVE_PATH:-}" ]]; then
    printf '%s\n' "$SWARM_ITERATE_ACTIVE_PATH"
    return 0
  fi
  printf '%s/_artifacts/active.md\n' "$(e2e_repo_root)"
}

swarm_iterate_ledger_path() {
  if [[ -n "${SWARM_ITERATE_LEDGER_PATH:-}" ]]; then
    printf '%s\n' "$SWARM_ITERATE_LEDGER_PATH"
    return 0
  fi
  printf '%s/_artifacts/ledger.md\n' "$(e2e_repo_root)"
}

# The canonical column header line. Both files must carry it verbatim.
swarm_iterate_table_header() {
  printf '| ID | Status | Severity | Subsystem | Iteration found | Iteration closed | Recording timestamps | Current behavior | Desired behavior | Evidence | Fix commit |\n'
}

# Allowed Status values per file. ledger.md only accepts Closed; active.md
# accepts Open or needs-verification.
swarm_iterate_active_status_allowed() {
  case "$1" in
    Open|needs-verification) return 0 ;;
    *) return 1 ;;
  esac
}

swarm_iterate_ledger_status_allowed() {
  [[ "$1" == "Closed" ]]
}

# Extracts the Iteration value from active.md header. Empty if absent.
swarm_iterate_active_iteration() {
  local active_path="$1"
  awk -F': ' '/^- Iteration: /{print $2; exit}' "$active_path"
}

# Lists all `L-####` IDs in a file (in document order, one per line).
swarm_iterate_collect_ids() {
  local path="$1"
  awk -F'|' '
    /^\| L-[0-9][0-9]*[[:space:]]*\|/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      print $2
    }
  ' "$path"
}

# Extracts the Status field of a row by ID. Empty if not found.
swarm_iterate_status_for_id() {
  local path="$1"
  local id="$2"
  awk -F'|' -v want="$id" '
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      if ($2 == want) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3)
        print $3
        exit
      }
    }
  ' "$path"
}

# Extracts the entire row line by ID (with leading/trailing whitespace).
# Empty if not found.
swarm_iterate_row_for_id() {
  local path="$1"
  local id="$2"
  awk -v want="$id" -F'|' '
    {
      tmp = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", tmp)
      if (tmp == want) {
        print $0
        exit
      }
    }
  ' "$path"
}
