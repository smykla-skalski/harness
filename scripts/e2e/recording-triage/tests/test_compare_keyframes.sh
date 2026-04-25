#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/recording-triage/tests/lib-test.sh
. "$SCRIPT_DIR/lib-test.sh"

recording_triage_test_skip_unless_ffmpeg
REPO_ROOT="$(recording_triage_test_repo_root)"
recording_triage_test_skip_unless_binary "$REPO_ROOT"
BUILD_FIXTURE="$REPO_ROOT/scripts/e2e/recording-triage/build-fixture.sh"
EXTRACT="$REPO_ROOT/scripts/e2e/recording-triage/extract-keyframes.sh"
COMPARE="$REPO_ROOT/scripts/e2e/recording-triage/compare-keyframes.sh"

WORK_DIR="$(recording_triage_test_make_run_dir compare)"
trap 'rm -rf "$WORK_DIR"' EXIT

FIXTURE_DIR="$WORK_DIR/fixtures"
"$BUILD_FIXTURE" "$FIXTURE_DIR" >/dev/null
RUN_DIR="$WORK_DIR/run"
recording_triage_test_seed_run "$RUN_DIR" "$FIXTURE_DIR/tiny.mov"

"$EXTRACT" --run "$RUN_DIR" --timestamp act1=0.020 >/dev/null

# Mirror the keyframe as the ground-truth snapshot so the perceptual hash
# distance is exactly 0.
mkdir -p "$RUN_DIR/ui-snapshots"
cp "$RUN_DIR/recording-triage/keyframes/act1.png" "$RUN_DIR/ui-snapshots/act1.png"

"$COMPARE" --run "$RUN_DIR" >/dev/null
REPORT="$RUN_DIR/recording-triage/compare-keyframes.json"
distance="$(jq '.[0].distance' "$REPORT")"
if [[ "$distance" != "0" ]]; then
  printf 'expected distance=0 for identical frame, got %s\n' "$distance" >&2
  exit 1
fi
printf 'compare-keyframes test ok\n'
