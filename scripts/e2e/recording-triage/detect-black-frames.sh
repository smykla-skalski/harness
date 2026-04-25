#!/usr/bin/env bash
set -euo pipefail

# Run the black-frame detector across every PNG already extracted into the
# run's recording-triage/keyframes directory.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/lib.sh
. "$SCRIPT_DIR/../lib.sh"
# shellcheck source=scripts/e2e/recording-triage/lib-recording-triage.sh
. "$SCRIPT_DIR/lib-recording-triage.sh"

usage() {
  cat <<'EOF' >&2
usage: detect-black-frames.sh --run <path> [--frames-dir <path>]
  --run           triage run dir
  --frames-dir    directory of PNGs to inspect (defaults to recording-triage/keyframes)
EOF
  exit 64
}

RUN_DIR=""
FRAMES_DIR=""
while (($#)); do
  case "$1" in
    --run) RUN_DIR="$2"; shift 2 ;;
    --frames-dir) FRAMES_DIR="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

recording_triage_require_run_dir "$RUN_DIR"
REPO_ROOT="$(recording_triage_repo_root)"
BINARY="$(recording_triage_resolve_binary "$REPO_ROOT")"

OUTPUT_DIR="$(recording_triage_output_dir "$RUN_DIR")"
FRAMES_DIR="${FRAMES_DIR:-$OUTPUT_DIR/keyframes}"
REPORT="$OUTPUT_DIR/black-frames.json"
mkdir -p "$OUTPUT_DIR"

declare -a FRAMES=()
shopt -s nullglob
for png in "$FRAMES_DIR"/*.png; do
  FRAMES+=("$png")
done

if (( ${#FRAMES[@]} == 0 )); then
  jq -nc '[]' >"$REPORT"
  printf 'detect-black-frames: no PNGs found in %s; emitted empty report\n' "$FRAMES_DIR"
  exit 0
fi

"$BINARY" recording-triage black-frames "${FRAMES[@]}" >"$REPORT"
printf 'detect-black-frames -> %s\n' "$REPORT"
