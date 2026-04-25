#!/usr/bin/env bash
set -euo pipefail

# Sample keyframes at a fixed interval across the recording, hash each, and let
# the Swift detector flag thrash windows.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/lib.sh
. "$SCRIPT_DIR/../lib.sh"
# shellcheck source=scripts/e2e/recording-triage/lib-recording-triage.sh
. "$SCRIPT_DIR/lib-recording-triage.sh"

usage() {
  cat <<'EOF' >&2
usage: detect-thrash.sh --run <path> [--interval <seconds>] [--max-samples N]
  --run           triage run dir
  --interval      sampling interval in seconds (default 0.1)
  --max-samples   safety cap on total samples (default 600)
EOF
  exit 64
}

RUN_DIR=""
INTERVAL="0.1"
MAX_SAMPLES="600"
while (($#)); do
  case "$1" in
    --run) RUN_DIR="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --max-samples) MAX_SAMPLES="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

recording_triage_require_run_dir "$RUN_DIR"
e2e_require_command ffmpeg
e2e_require_command ffprobe
REPO_ROOT="$(recording_triage_repo_root)"
BINARY="$(recording_triage_resolve_binary "$REPO_ROOT")"

RECORDING="$RUN_DIR/swarm-full-flow.mov"
OUTPUT_DIR="$(recording_triage_output_dir "$RUN_DIR")"
SAMPLE_DIR="$OUTPUT_DIR/thrash-samples"
mkdir -p "$SAMPLE_DIR"
REPORT="$OUTPUT_DIR/thrash.json"

DURATION="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$RECORDING")"
declare -a CLI_ARGS=()
COUNT=0
SECONDS_TIME="0.0"
# Stop one INTERVAL short of the duration so ffmpeg never seeks past the last
# valid frame; float comparisons against the bare duration miss by epsilon and
# yield invalid PNGs that the Swift detector can't decode.
while awk -v s="$SECONDS_TIME" -v d="$DURATION" -v step="$INTERVAL" \
  'BEGIN { exit !(s + 0.0 + step + 0.0 <= d + 0.0) }'; do
  if (( COUNT >= MAX_SAMPLES )); then break; fi
  output="$SAMPLE_DIR/sample-$(printf '%05d' "$COUNT").png"
  if ! ffmpeg -y -loglevel error -ss "$SECONDS_TIME" -i "$RECORDING" -frames:v 1 "$output"; then
    break
  fi
  if [[ ! -s "$output" ]]; then
    break
  fi
  CLI_ARGS+=(--sample "${SECONDS_TIME}=${output}")
  COUNT=$((COUNT + 1))
  SECONDS_TIME="$(awk -v s="$SECONDS_TIME" -v step="$INTERVAL" 'BEGIN { printf "%.6f", s + step }')"
done

if (( ${#CLI_ARGS[@]} < 2 )); then
  jq -nc '{windowSeconds:0.5, changeThreshold:3, windows:[]}' >"$REPORT"
  printf 'detect-thrash: too few samples; emitted empty report\n'
  exit 0
fi

"$BINARY" recording-triage thrash "${CLI_ARGS[@]}" >"$REPORT"
printf 'detect-thrash -> %s\n' "$REPORT"
