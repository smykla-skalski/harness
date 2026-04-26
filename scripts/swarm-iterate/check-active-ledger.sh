#!/usr/bin/env bash
# check-active-ledger.sh
#
# Validates the swarm-e2e-iterate ledger system invariants:
#   - both files exist (or both absent, in which case nothing to check)
#   - active.md carries the documented header keys
#   - both tables share the canonical column header
#   - no L-#### ID appears in both files
#   - active.md rows are Open or needs-verification only
#   - ledger.md rows are Closed only
#   - IDs are unique within each file
#
# Exits 0 when all invariants hold. Exits 1 with a descriptive error
# on the first violation. Exits 0 silently when both files are absent
# (clean repo, no swarm work yet).

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/swarm-iterate/lib.sh
. "$SCRIPT_DIR/lib.sh"

active_path="$(swarm_iterate_active_path)"
ledger_path="$(swarm_iterate_ledger_path)"
header_line="$(swarm_iterate_table_header)"

active_present=0
ledger_present=0
[[ -f "$active_path" ]] && active_present=1
[[ -f "$ledger_path" ]] && ledger_present=1

if (( active_present == 0 && ledger_present == 0 )); then
  # Nothing to validate; no swarm work has started in this checkout.
  exit 0
fi

if (( active_present == 0 )); then
  printf 'error: ledger.md exists but active.md is missing: %s\n' "$active_path" >&2
  exit 1
fi
if (( ledger_present == 0 )); then
  printf 'error: active.md exists but ledger.md is missing: %s\n' "$ledger_path" >&2
  exit 1
fi

require_header_keys=(
  '- Iteration: '
  '- Last run slug: '
  '- Last status: '
  '- Last terminated at: '
)
for key in "${require_header_keys[@]}"; do
  if ! grep -q -F -- "$key" "$active_path"; then
    printf 'error: active.md missing header key %q\n' "$key" >&2
    exit 1
  fi
done

if ! grep -q -F -- "$header_line" "$active_path"; then
  printf 'error: active.md missing canonical column header\n' >&2
  exit 1
fi
if ! grep -q -F -- "$header_line" "$ledger_path"; then
  printf 'error: ledger.md missing canonical column header\n' >&2
  exit 1
fi

# IDs unique within each file.
duplicate_active="$(swarm_iterate_collect_ids "$active_path" | sort | uniq -d || true)"
if [[ -n "$duplicate_active" ]]; then
  printf 'error: active.md contains duplicate IDs:\n%s\n' "$duplicate_active" >&2
  exit 1
fi
duplicate_ledger="$(swarm_iterate_collect_ids "$ledger_path" | sort | uniq -d || true)"
if [[ -n "$duplicate_ledger" ]]; then
  printf 'error: ledger.md contains duplicate IDs:\n%s\n' "$duplicate_ledger" >&2
  exit 1
fi

# Cross-file: no ID appears in both.
collisions="$(
  comm -12 \
    <(swarm_iterate_collect_ids "$active_path" | sort -u) \
    <(swarm_iterate_collect_ids "$ledger_path" | sort -u) \
    || true
)"
if [[ -n "$collisions" ]]; then
  printf 'error: rows present in both active.md and ledger.md (must move atomically):\n%s\n' "$collisions" >&2
  exit 1
fi

# Status enum per file.
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  status="$(swarm_iterate_status_for_id "$active_path" "$id")"
  if ! swarm_iterate_active_status_allowed "$status"; then
    printf 'error: active.md row %s has Status=%q (expected Open or needs-verification)\n' "$id" "$status" >&2
    exit 1
  fi
done < <(swarm_iterate_collect_ids "$active_path")

while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  status="$(swarm_iterate_status_for_id "$ledger_path" "$id")"
  if ! swarm_iterate_ledger_status_allowed "$status"; then
    printf 'error: ledger.md row %s has Status=%q (expected Closed)\n' "$id" "$status" >&2
    exit 1
  fi
done < <(swarm_iterate_collect_ids "$ledger_path")

active_count="$(swarm_iterate_collect_ids "$active_path" | wc -l | tr -d ' ')"
ledger_count="$(swarm_iterate_collect_ids "$ledger_path" | wc -l | tr -d ' ')"
printf 'ledger system clean: %s active, %s closed\n' "$active_count" "$ledger_count"
