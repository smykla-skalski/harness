#!/usr/bin/env bash
set -euo pipefail

# Pair extracted keyframes against ui-snapshots/<actN>.png ground truth and run
# the perceptual-hash comparator. Pairs are inferred from filenames so a
# keyframe at recording-triage/keyframes/act5.png matches ui-snapshots/act5.png.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/lib.sh
. "$SCRIPT_DIR/../lib.sh"
# shellcheck source=scripts/e2e/recording-triage/lib-recording-triage.sh
. "$SCRIPT_DIR/lib-recording-triage.sh"

usage() {
  cat <<'EOF' >&2
usage: compare-keyframes.sh --run <path> [--snapshots-dir <path>]
  --run             triage run dir containing recording-triage/keyframes/
  --snapshots-dir   ground-truth ui-snapshots dir (defaults to <run>/ui-snapshots)
EOF
  exit 64
}

RUN_DIR=""
SNAPSHOTS_DIR=""
while (($#)); do
  case "$1" in
    --run) RUN_DIR="$2"; shift 2 ;;
    --snapshots-dir) SNAPSHOTS_DIR="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

recording_triage_require_run_dir "$RUN_DIR"
REPO_ROOT="$(recording_triage_repo_root)"
BINARY="$(recording_triage_resolve_binary "$REPO_ROOT")"

KEYFRAMES_DIR="$(recording_triage_output_dir "$RUN_DIR")/keyframes"
SNAPSHOTS_DIR="${SNAPSHOTS_DIR:-$RUN_DIR/ui-snapshots}"
REPORT="$(recording_triage_output_dir "$RUN_DIR")/compare-keyframes.json"
mkdir -p "$(dirname -- "$REPORT")"

declare -a CLI_ARGS=()
shopt -s nullglob
for keyframe in "$KEYFRAMES_DIR"/*.png; do
  base="$(basename -- "$keyframe" .png)"
  ground="$SNAPSHOTS_DIR/${base}.png"
  if [[ -f "$ground" ]]; then
    CLI_ARGS+=(--candidate "${base}=${keyframe}" --ground-truth "${base}=${ground}")
  fi
done

if (( ${#CLI_ARGS[@]} == 0 )); then
  jq -nc '[]' >"$REPORT"
  printf 'compare-keyframes: no candidate/ground-truth pairs found; emitted empty report\n'
  exit 0
fi

"$BINARY" recording-triage compare-frames "${CLI_ARGS[@]}" >"$REPORT"
printf 'compare-keyframes -> %s\n' "$REPORT"
