#!/usr/bin/env bash
set -euo pipefail

# Run ffprobe -show_frames against the run's swarm-full-flow.mov and dispatch to
# the harness-monitor-e2e Swift detector for hitch/freeze/stall classification.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/lib.sh
. "$SCRIPT_DIR/../lib.sh"
# shellcheck source=scripts/e2e/recording-triage/lib-recording-triage.sh
. "$SCRIPT_DIR/lib-recording-triage.sh"

usage() {
  cat <<'EOF' >&2
usage: frame-gaps.sh --run <path> [--idle-segment START:END]...
  --run             triage run dir containing swarm-full-flow.mov
  --idle-segment    repeatable seconds range counted as idle (stalls allowed)
EOF
  exit 64
}

RUN_DIR=""
declare -a IDLE_ARGS=()
while (($#)); do
  case "$1" in
    --run) RUN_DIR="$2"; shift 2 ;;
    --idle-segment) IDLE_ARGS+=("--idle-segment" "$2"); shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

recording_triage_require_run_dir "$RUN_DIR"
e2e_require_command ffprobe
REPO_ROOT="$(recording_triage_repo_root)"
BINARY="$(recording_triage_resolve_binary "$REPO_ROOT")"

RECORDING="$RUN_DIR/swarm-full-flow.mov"
OUTPUT_DIR="$(recording_triage_output_dir "$RUN_DIR")"
mkdir -p "$OUTPUT_DIR"
PROBE_OUT="$OUTPUT_DIR/ffprobe-frames.txt"
REPORT="$OUTPUT_DIR/frame-gaps.json"

ffprobe -v error -show_frames -of compact=p=0 "$RECORDING" >"$PROBE_OUT"

"$BINARY" recording-triage frame-gaps \
  --ffprobe-output "$PROBE_OUT" \
  "${IDLE_ARGS[@]}" >"$REPORT"

printf 'frame-gaps -> %s\n' "$REPORT"
