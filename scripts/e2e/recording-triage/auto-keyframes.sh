#!/usr/bin/env bash
set -euo pipefail

# Derive per-act timestamps from `<run>/context/sync-root/e2e-sync/actN.ready`
# mtimes (seconds offset from the recording-started line in
# screen-recording.log), then dispatch the existing `extract-keyframes.sh` and
# `compare-keyframes.sh` wrappers. Writes `recording-triage/auto-keyframes.json`
# summarising the per-act timestamps + paths to the intermediate JSONs.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/recording-triage/lib-recording-triage.sh
. "$SCRIPT_DIR/lib-recording-triage.sh"

usage() {
  cat <<'EOF' >&2
usage: auto-keyframes.sh --run <path>
  --run     triage run dir containing swarm-full-flow.mov, screen-recording.log,
            and context/sync-root/e2e-sync/actN.ready markers
EOF
  exit 64
}

RUN_DIR=""
while (($#)); do
  case "$1" in
    --run) RUN_DIR="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

recording_triage_require_run_dir "$RUN_DIR"
SCREEN_LOG="$RUN_DIR/screen-recording.log"
MARKER_DIR="$RUN_DIR/context/sync-root/e2e-sync"
RECORDING="$RUN_DIR/swarm-full-flow.mov"
for required in "$SCREEN_LOG" "$MARKER_DIR" "$RECORDING"; do
  if [[ ! -e "$required" ]]; then
    printf 'error: missing input: %s\n' "$required" >&2
    exit 1
  fi
done

REC_LINE="$(grep -m1 'recording-started' "$SCREEN_LOG" || true)"
if [[ -z "$REC_LINE" ]]; then
  printf 'error: no recording-started line in %s\n' "$SCREEN_LOG" >&2
  exit 1
fi
REC_ISO="${REC_LINE%% *}"

REC_EPOCH="$(python3 - "$REC_ISO" <<'PY'
import datetime
import sys

raw = sys.argv[1]
if raw.endswith("Z"):
    raw = raw[:-1] + "+00:00"
print(datetime.datetime.fromisoformat(raw).timestamp())
PY
)"

mtime_seconds() {
  python3 -c 'import os, sys; print(os.path.getmtime(sys.argv[1]))' "$1"
}

declare -a TIMESTAMP_PAIRS=()
declare -a SUMMARY_LINES=()
shopt -s nullglob
for ready in "$MARKER_DIR"/act*.ready; do
  base="$(basename -- "$ready" .ready)"
  marker_mtime="$(mtime_seconds "$ready")"
  offset="$(awk -v m="$marker_mtime" -v r="$REC_EPOCH" 'BEGIN{printf "%.6f", m - r}')"
  if awk -v o="$offset" 'BEGIN{exit !(o < 0)}'; then
    printf 'skipping %s (negative offset %s)\n' "$base" "$offset" >&2
    continue
  fi
  name="swarm-${base}"
  TIMESTAMP_PAIRS+=("--timestamp" "${name}=${offset}")
  SUMMARY_LINES+=("$(jq -nc --arg name "$name" --arg seconds "$offset" '{name:$name, seconds:($seconds|tonumber)}')")
done

OUTPUT_DIR="$(recording_triage_output_dir "$RUN_DIR")"
mkdir -p "$OUTPUT_DIR"
SUMMARY="$OUTPUT_DIR/auto-keyframes.json"

if (( ${#TIMESTAMP_PAIRS[@]} == 0 )); then
  jq -n '{recordingStartIso: $start, acts: [], keyframes: null, compare: null}' \
    --arg start "$REC_ISO" >"$SUMMARY"
  printf 'auto-keyframes -> %s (no act markers)\n' "$SUMMARY"
  exit 0
fi

"$SCRIPT_DIR/extract-keyframes.sh" --run "$RUN_DIR" "${TIMESTAMP_PAIRS[@]}" >/dev/null
"$SCRIPT_DIR/compare-keyframes.sh" --run "$RUN_DIR" >/dev/null

jq -n \
  --arg start "$REC_ISO" \
  --argjson acts "$(jq -s '.' < <(printf '%s\n' "${SUMMARY_LINES[@]}"))" \
  --arg keyframes "$OUTPUT_DIR/keyframes.json" \
  --arg compare "$OUTPUT_DIR/compare-keyframes.json" \
  '{recordingStartIso: $start, acts: $acts, keyframes: $keyframes, compare: $compare}' \
  >"$SUMMARY"

printf 'auto-keyframes -> %s\n' "$SUMMARY"
