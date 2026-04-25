#!/usr/bin/env bash
set -euo pipefail

# Build deterministic tiny .mov fixtures used by RecordingTriage tests and
# recording-triage shell tests. Idempotent: re-running with existing outputs
# rebuilds them so detector tests see the documented inputs.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/lib.sh
. "$SCRIPT_DIR/../lib.sh"

REPO_ROOT="$(e2e_repo_root)"
OUTPUT_DIR_DEFAULT="$REPO_ROOT/apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Tests/Fixtures"
OUTPUT_DIR="${1:-$OUTPUT_DIR_DEFAULT}"

e2e_require_command ffmpeg
e2e_require_command ffprobe

mkdir -p "$OUTPUT_DIR"

build_fixture() {
  local output="$1"
  local lavfi="$2"
  ffmpeg -y -loglevel error \
    -f lavfi -i "$lavfi" \
    -t 0.2 -r 24 -pix_fmt yuv420p \
    -c:v libx264 -preset ultrafast -crf 28 \
    "$output"
}

# tiny.mov: solid blue 24 fps (5 frames). Stable hash, no thrash, no transitions.
build_fixture "$OUTPUT_DIR/tiny.mov" "color=color=blue:size=160x120:rate=24"

# transition.mov: blue->red half-second swap simulates a deliberate state change.
ffmpeg -y -loglevel error \
  -f lavfi -i "color=color=blue:size=160x120:rate=24:duration=0.1" \
  -f lavfi -i "color=color=red:size=160x120:rate=24:duration=0.1" \
  -filter_complex "[0:v][1:v]concat=n=2:v=1:a=0[v]" \
  -map "[v]" -t 0.2 -r 24 -pix_fmt yuv420p \
  -c:v libx264 -preset ultrafast -crf 28 \
  "$OUTPUT_DIR/transition.mov"

# freeze.mov: solid black exposes the black-frame detector path.
build_fixture "$OUTPUT_DIR/freeze.mov" "color=color=black:size=160x120:rate=24"

printf 'tiny.mov:       %s\n' "$OUTPUT_DIR/tiny.mov"
printf 'transition.mov: %s\n' "$OUTPUT_DIR/transition.mov"
printf 'freeze.mov:     %s\n' "$OUTPUT_DIR/freeze.mov"
