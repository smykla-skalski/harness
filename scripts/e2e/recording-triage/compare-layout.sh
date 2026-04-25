#!/usr/bin/env bash
set -euo pipefail

# Walk consecutive `swarm-act{N,N+1}.txt` accessibility hierarchy dumps inside
# `<run-dir>/ui-snapshots/` and call `harness-monitor-e2e recording-triage
# layout-drift` for each pair. The aggregated report lands at
# `<run-dir>/recording-triage/layout-drift.json` shaped as
# `{ "pairs": [{ "before": "swarm-actN", "after": "swarm-actN+1", "drifts": [...] }] }`.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/recording-triage/lib-recording-triage.sh
. "$SCRIPT_DIR/lib-recording-triage.sh"

usage() {
  cat <<'EOF' >&2
usage: compare-layout.sh --run <path> [--threshold <points>]
  --run        triage run dir containing ui-snapshots/swarm-act*.txt dumps
  --threshold  minimum dx/dy in points to flag drift (default forwarded to layout-drift)
EOF
  exit 64
}

RUN_DIR=""
THRESHOLD=""
while (($#)); do
  case "$1" in
    --run) RUN_DIR="$2"; shift 2 ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

recording_triage_require_run_dir "$RUN_DIR"
REPO_ROOT="$(recording_triage_repo_root)"
BINARY="$(recording_triage_resolve_binary "$REPO_ROOT")"

SNAPSHOT_DIR="$RUN_DIR/ui-snapshots"
OUTPUT_DIR="$(recording_triage_output_dir "$RUN_DIR")"
mkdir -p "$OUTPUT_DIR"
REPORT="$OUTPUT_DIR/layout-drift.json"
if [[ ! -d "$SNAPSHOT_DIR" ]]; then
  printf '{ "pairs": [] }\n' >"$REPORT"
  printf 'compare-layout -> %s (ui-snapshots dir missing)\n' "$REPORT"
  exit 0
fi

# Collect swarm-actN.txt sorted by N (numeric, not lexicographic).
SNAPSHOTS=()
while IFS= read -r entry; do
  SNAPSHOTS+=("$entry")
done < <(
  find "$SNAPSHOT_DIR" -maxdepth 1 -type f -name 'swarm-act*.txt' \
    -printf '%f\n' 2>/dev/null \
    | awk '{ name = $0; sub(/^swarm-act/, "", name); sub(/\.txt$/, "", name); printf "%s\t%s\n", name, $0 }' \
    | sort -n -k1,1 \
    | cut -f2
)

if (( ${#SNAPSHOTS[@]} < 2 )); then
  printf '{ "pairs": [] }\n' >"$REPORT"
  printf 'compare-layout -> %s (no snapshot pairs)\n' "$REPORT"
  exit 0
fi

WORK_DIR="$(mktemp -d -t recording-triage-compare-layout.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
PAIRS_FILE="$WORK_DIR/pairs.json"
printf '[]' >"$PAIRS_FILE"

idx=0
end=$(( ${#SNAPSHOTS[@]} - 1 ))
while (( idx < end )); do
  before_name="${SNAPSHOTS[idx]}"
  after_name="${SNAPSHOTS[idx + 1]}"
  before_path="$SNAPSHOT_DIR/$before_name"
  after_path="$SNAPSHOT_DIR/$after_name"
  pair_json="$WORK_DIR/pair-$idx.json"
  if [[ -n "$THRESHOLD" ]]; then
    "$BINARY" recording-triage layout-drift \
      --before "$before_path" --after "$after_path" \
      --threshold "$THRESHOLD" >"$pair_json"
  else
    "$BINARY" recording-triage layout-drift \
      --before "$before_path" --after "$after_path" >"$pair_json"
  fi
  before_stem="${before_name%.txt}"
  after_stem="${after_name%.txt}"
  next="$WORK_DIR/pairs-next.json"
  jq --arg before "$before_stem" --arg after "$after_stem" \
    --slurpfile drifts "$pair_json" \
    '. + [{ before: $before, after: $after, drifts: $drifts[0] }]' \
    "$PAIRS_FILE" >"$next"
  mv "$next" "$PAIRS_FILE"
  idx=$(( idx + 1 ))
done

jq '{ pairs: . }' "$PAIRS_FILE" >"$REPORT"
printf 'compare-layout -> %s\n' "$REPORT"
