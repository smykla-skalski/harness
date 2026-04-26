#!/usr/bin/env bash
# close-finding.sh <id> <short-sha>
#
# Atomically moves a row from the active findings file to the closed archive:
#   1. reads the matching `| <id> |` row from _artifacts/active.md
#   2. rewrites Status -> Closed, fills Iteration closed from header,
#      fills Fix commit with <short-sha>
#   3. appends the rewritten row to _artifacts/ledger.md
#   4. deletes the original row from active.md
#   5. asserts <id> appears exactly once in ledger.md and not at all
#      in active.md
#
# Writes via mktemp + mv rename, so a crash mid-write leaves the prior
# good state on disk. Exits non-zero on any pre-condition or invariant
# break without mutating either file.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/swarm-iterate/lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  printf 'usage: %s <id> <short-sha>\n' "$(basename -- "$0")" >&2
}

if [[ "$#" -ne 2 ]]; then
  usage
  exit 64
fi

readonly ID="$1"
readonly SHA="$2"

if [[ ! "$ID" =~ ^L-[0-9]{4,}$ ]]; then
  printf 'error: id %q must match L-#### (zero-padded sequential)\n' "$ID" >&2
  exit 65
fi

if [[ ! "$SHA" =~ ^[0-9a-f]{7,40}$ ]]; then
  printf 'error: sha %q must be a 7-40 char lowercase hex short SHA\n' "$SHA" >&2
  exit 65
fi

active_path="$(swarm_iterate_active_path)"
ledger_path="$(swarm_iterate_ledger_path)"

if [[ ! -f "$active_path" ]]; then
  printf 'error: active file missing: %s\n' "$active_path" >&2
  exit 66
fi
if [[ ! -f "$ledger_path" ]]; then
  printf 'error: ledger file missing: %s\n' "$ledger_path" >&2
  exit 66
fi

iteration="$(swarm_iterate_active_iteration "$active_path")"
if [[ -z "$iteration" ]]; then
  # shellcheck disable=SC2016
  printf 'error: %s missing `- Iteration: <N>` header line\n' "$active_path" >&2
  exit 66
fi

row="$(swarm_iterate_row_for_id "$active_path" "$ID")"
if [[ -z "$row" ]]; then
  printf 'error: row %s not found in %s\n' "$ID" "$active_path" >&2
  exit 67
fi

if [[ -n "$(swarm_iterate_row_for_id "$ledger_path" "$ID")" ]]; then
  printf 'error: row %s already exists in %s; refusing to duplicate\n' "$ID" "$ledger_path" >&2
  exit 68
fi

# Build the rewritten row. Markdown table rows look like:
#   | <id> | Status | Severity | Subsystem | Iter found | Iter closed | ...
# Splitting on `|` yields a leading empty field, then 11 column fields, then
# a trailing empty field. We rewrite columns 2 (Status), 6 (Iteration closed)
# and 12 (Fix commit) and re-emit.
rewritten_row="$(
  awk -v id="$ID" -v sha="$SHA" -v iter="$iteration" '
    BEGIN { FS = "|"; OFS = "|" }
    {
      total = NF
      # columns count is total - 2 because of leading and trailing empty fields
      # produced by leading/trailing pipes in the markdown row
      for (i = 1; i <= total; i++) {
        field = $i
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", field)
        $i = field
      }
      # column 2 = ID, column 3 = Status, column 7 = Iteration closed, column 12 = Fix commit
      $3 = "Closed"
      $7 = iter
      $12 = sha
      # re-pad with single spaces around each value to match canonical style
      out = ""
      for (i = 1; i <= total; i++) {
        if (i == 1 || i == total) {
          out = out $i "|"
        } else {
          out = out " " $i " |"
        }
      }
      # strip the trailing pipe added by the loop and prepend back the leading
      sub(/\|$/, "", out)
      print out
      exit
    }
  ' <<<"$row"
)"

if [[ -z "$rewritten_row" ]]; then
  printf 'error: failed to rewrite row %s\n' "$ID" >&2
  exit 70
fi

# Stage active.md without the row.
active_tmp="$(mktemp "${active_path}.tmp.XXXXXX")"
trap 'rm -f "$active_tmp" "$ledger_tmp"' EXIT

awk -v id="$ID" -F'|' '
  {
    tmp = $2
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", tmp)
    if (tmp == id) next
    print
  }
' "$active_path" >"$active_tmp"

# Stage ledger.md with the row appended (preserve trailing newline behaviour).
ledger_tmp="$(mktemp "${ledger_path}.tmp.XXXXXX")"
cat "$ledger_path" >"$ledger_tmp"
# Ensure ledger ends in a newline before appending.
if [[ -s "$ledger_tmp" ]]; then
  last_byte="$(tail -c 1 "$ledger_tmp" || true)"
  if [[ "$last_byte" != $'\n' ]]; then
    printf '\n' >>"$ledger_tmp"
  fi
fi
printf '%s\n' "$rewritten_row" >>"$ledger_tmp"

# Promote both staged files atomically (mv is atomic within the same fs).
mv "$active_tmp" "$active_path"
mv "$ledger_tmp" "$ledger_path"
trap - EXIT

# Post-conditions.
active_hits="$(swarm_iterate_collect_ids "$active_path" | grep -cxF -- "$ID" || true)"
ledger_hits="$(swarm_iterate_collect_ids "$ledger_path" | grep -cxF -- "$ID" || true)"

if [[ "$active_hits" != "0" ]]; then
  printf 'error: invariant break: row %s still appears in active.md (%s occurrence(s))\n' "$ID" "$active_hits" >&2
  exit 71
fi
if [[ "$ledger_hits" != "1" ]]; then
  printf 'error: invariant break: row %s appears %s time(s) in ledger.md (expected 1)\n' "$ID" "$ledger_hits" >&2
  exit 71
fi

# Confirm the appended row carries the expected Status/sha.
final_status="$(swarm_iterate_status_for_id "$ledger_path" "$ID")"
if [[ "$final_status" != "Closed" ]]; then
  printf 'error: invariant break: row %s landed in ledger with Status=%q (expected Closed)\n' "$ID" "$final_status" >&2
  exit 71
fi

printf 'closed %s -> %s (sha %s, iteration %s)\n' "$ID" "$ledger_path" "$SHA" "$iteration"
