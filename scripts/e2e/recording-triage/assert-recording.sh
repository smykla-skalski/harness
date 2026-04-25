#!/usr/bin/env bash
set -euo pipefail

# Pre-flight that the swarm-full-flow.mov exists, is in the expected size band,
# and is ffprobe-readable. Called as the first step of run-all.sh.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/lib.sh
. "$SCRIPT_DIR/../lib.sh"
# shellcheck source=scripts/e2e/recording-triage/lib-recording-triage.sh
. "$SCRIPT_DIR/lib-recording-triage.sh"

usage() {
  cat <<'EOF' >&2
usage: assert-recording.sh --run <path> [--min-size <bytes>] [--max-size <bytes>]
  --run        triage run dir containing swarm-full-flow.mov
  --min-size   minimum acceptable size in bytes (default 5 MB)
  --max-size   maximum acceptable size in bytes (default 2 GB)
EOF
  exit 64
}

RUN_DIR=""
MIN_SIZE=5242880
MAX_SIZE=2147483648
while (($#)); do
  case "$1" in
    --run) RUN_DIR="$2"; shift 2 ;;
    --min-size) MIN_SIZE="$2"; shift 2 ;;
    --max-size) MAX_SIZE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

recording_triage_require_run_dir "$RUN_DIR"
e2e_require_command ffprobe

RECORDING="$RUN_DIR/swarm-full-flow.mov"
OUTPUT_DIR="$(recording_triage_output_dir "$RUN_DIR")"
mkdir -p "$OUTPUT_DIR"
REPORT="$OUTPUT_DIR/assert-recording.json"

emit_failure() {
  local reason="$1"
  jq -nc --arg reason "$reason" --arg recording "$RECORDING" \
    '{status:"failed", reason:$reason, recording:$recording}' >"$REPORT"
  printf '%s\n' "$reason" >&2
  exit 1
}

if [[ ! -s "$RECORDING" ]]; then
  emit_failure "swarm-full-flow.mov missing or empty: $RECORDING"
fi

SIZE_BYTES="$(stat -f%z "$RECORDING" 2>/dev/null || stat -c%s "$RECORDING")"
if (( SIZE_BYTES < MIN_SIZE )); then
  emit_failure "recording smaller than $MIN_SIZE bytes ($SIZE_BYTES); likely truncated"
fi
if (( SIZE_BYTES > MAX_SIZE )); then
  emit_failure "recording larger than $MAX_SIZE bytes ($SIZE_BYTES); likely runaway"
fi

if ! DURATION="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$RECORDING")"; then
  emit_failure "ffprobe could not read recording"
fi

jq -nc \
  --arg recording "$RECORDING" \
  --arg duration "$DURATION" \
  --argjson size_bytes "$SIZE_BYTES" \
  '{status:"ok", recording:$recording, duration_seconds:($duration|tonumber), size_bytes:$size_bytes}' \
  >"$REPORT"
printf 'assert-recording ok: %s\n' "$REPORT"
