#!/usr/bin/env bash
set -euo pipefail

# Extract a still PNG keyframe at each requested timestamp. Emits a JSON
# manifest listing the saved frames so downstream detectors can pair them with
# act names without re-deriving timestamps.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/lib.sh
. "$SCRIPT_DIR/../lib.sh"
# shellcheck source=scripts/e2e/recording-triage/lib-recording-triage.sh
. "$SCRIPT_DIR/lib-recording-triage.sh"

usage() {
  cat <<'EOF' >&2
usage: extract-keyframes.sh --run <path> --timestamp NAME=SECONDS [--timestamp ...]
  --run         triage run dir containing swarm-full-flow.mov
  --timestamp   repeatable NAME=SECONDS pair to extract
EOF
  exit 64
}

RUN_DIR=""
declare -a TIMESTAMP_PAIRS=()
while (($#)); do
  case "$1" in
    --run) RUN_DIR="$2"; shift 2 ;;
    --timestamp) TIMESTAMP_PAIRS+=("$2"); shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

recording_triage_require_run_dir "$RUN_DIR"
e2e_require_command ffmpeg

if (( ${#TIMESTAMP_PAIRS[@]} == 0 )); then
  printf 'extract-keyframes requires at least one --timestamp NAME=SECONDS\n' >&2
  exit 64
fi

RECORDING="$RUN_DIR/swarm-full-flow.mov"
OUTPUT_DIR="$(recording_triage_output_dir "$RUN_DIR")/keyframes"
mkdir -p "$OUTPUT_DIR"
MANIFEST="$(recording_triage_output_dir "$RUN_DIR")/keyframes.json"

declare -a MANIFEST_LINES=()
for entry in "${TIMESTAMP_PAIRS[@]}"; do
  name="${entry%%=*}"
  seconds="${entry#*=}"
  if [[ -z "$name" || -z "$seconds" || "$name" == "$seconds" ]]; then
    printf 'invalid --timestamp pair: %s\n' "$entry" >&2
    exit 64
  fi
  output="$OUTPUT_DIR/${name}.png"
  ffmpeg -y -loglevel error -ss "$seconds" -i "$RECORDING" -frames:v 1 "$output"
  MANIFEST_LINES+=("$(jq -nc --arg name "$name" --arg seconds "$seconds" --arg path "$output" \
    '{name:$name, seconds:($seconds|tonumber), path:$path}')")
done

jq -s '.' < <(printf '%s\n' "${MANIFEST_LINES[@]}") >"$MANIFEST"
printf 'extract-keyframes wrote %d frames -> %s\n' "${#TIMESTAMP_PAIRS[@]}" "$MANIFEST"
