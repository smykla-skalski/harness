#!/usr/bin/env bash
#
# Render every entry in Previews.json serially and produce a summary.
# Fails non-zero if any entry fails or total wall time exceeds budget.
#
# Environment:
#   PREVIEW_SMOKE_BUDGET_SECONDS  total wall time budget (default 600)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$PROJECT_DIR/Previews.json"
OUT_DIR="$PROJECT_DIR/tmp/previews"
BUDGET="${PREVIEW_SMOKE_BUDGET_SECONDS:-600}"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required tool '$1' not installed" >&2
    exit 127
  }
}

require xcode-cli
require jq

[[ -f "$MANIFEST" ]] || {
  echo "error: manifest not found at $MANIFEST" >&2
  exit 1
}

mkdir -p "$OUT_DIR"
summary_path="$OUT_DIR/summary.json"

start_epoch=$(date +%s)
ids=()
while IFS= read -r id; do
  ids+=("$id")
done < <(jq -r '.entries[].id' "$MANIFEST")

total=${#ids[@]}
pass=0
fail=0
results=()

for id in "${ids[@]}"; do
  echo "---[$((pass + fail + 1))/$total] $id---" >&2
  if "$SCRIPT_DIR/preview-render.sh" --id "$id" >/dev/null; then
    pass=$((pass + 1))
    status="pass"
  else
    fail=$((fail + 1))
    status="fail"
  fi
  meta="$OUT_DIR/$id.json"
  if [[ -f "$meta" ]]; then
    results+=("$(jq --arg status "$status" '. + {status:$status}' "$meta")")
  else
    results+=("$(jq -n --arg id "$id" --arg status "$status" '{id:$id, status:$status}')")
  fi
done

end_epoch=$(date +%s)
elapsed=$((end_epoch - start_epoch))

printf '[' > "$summary_path.tmp"
first=true
for entry in "${results[@]}"; do
  if $first; then
    first=false
  else
    printf ',' >> "$summary_path.tmp"
  fi
  printf '%s' "$entry" >> "$summary_path.tmp"
done
printf ']' >> "$summary_path.tmp"

jq -n \
  --argjson total "$total" \
  --argjson pass "$pass" \
  --argjson fail "$fail" \
  --argjson elapsed "$elapsed" \
  --argjson budget "$BUDGET" \
  --slurpfile results "$summary_path.tmp" \
  '{total:$total, pass:$pass, fail:$fail, elapsed_seconds:$elapsed, budget_seconds:$budget, results:$results[0]}' \
  > "$summary_path"
rm -f "$summary_path.tmp"

echo "preview smoke: $pass/$total passed in ${elapsed}s (budget ${BUDGET}s)" >&2
echo "summary: $summary_path" >&2

if (( fail > 0 )); then
  echo "FAIL: $fail preview(s) failed" >&2
  exit 1
fi
if (( elapsed > BUDGET )); then
  echo "FAIL: elapsed ${elapsed}s exceeds budget ${BUDGET}s" >&2
  exit 1
fi
echo "PASS" >&2
