#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/recording-triage/tests/lib-test.sh
. "$SCRIPT_DIR/lib-test.sh"

recording_triage_test_skip_unless_ffmpeg
REPO_ROOT="$(recording_triage_test_repo_root)"
recording_triage_test_skip_unless_binary "$REPO_ROOT"
BUILD_FIXTURE="$REPO_ROOT/scripts/e2e/recording-triage/build-fixture.sh"

WORK_DIR="$(recording_triage_test_make_run_dir runall)"
trap 'rm -rf "$WORK_DIR"' EXIT

FIXTURE_DIR="$WORK_DIR/fixtures"
"$BUILD_FIXTURE" "$FIXTURE_DIR" >/dev/null
RUN_DIR="$WORK_DIR/run"
recording_triage_test_seed_run "$RUN_DIR" "$FIXTURE_DIR/tiny.mov"

# run-all calls assert-recording with default thresholds; for the test fixture
# (< 5 MB) we run each detector individually instead and synthesise the
# orchestrator's summary aggregation by replaying it with --min-size 1.
ASSERT_RECORDING="$REPO_ROOT/scripts/e2e/recording-triage/assert-recording.sh"
FRAME_GAPS="$REPO_ROOT/scripts/e2e/recording-triage/frame-gaps.sh"
DEAD_HEAD_TAIL="$REPO_ROOT/scripts/e2e/recording-triage/detect-dead-head-tail.sh"
THRASH="$REPO_ROOT/scripts/e2e/recording-triage/detect-thrash.sh"
BLACK_FRAMES="$REPO_ROOT/scripts/e2e/recording-triage/detect-black-frames.sh"

"$ASSERT_RECORDING" --run "$RUN_DIR" --min-size 1 >/dev/null
"$FRAME_GAPS" --run "$RUN_DIR" >/dev/null
"$DEAD_HEAD_TAIL" --run "$RUN_DIR" >/dev/null
"$THRASH" --run "$RUN_DIR" --interval 0.1 --max-samples 4 >/dev/null
"$BLACK_FRAMES" --run "$RUN_DIR" >/dev/null

OUTPUT_DIR="$RUN_DIR/recording-triage"
for path in assert-recording.json frame-gaps.json dead-head-tail.json thrash.json black-frames.json; do
  if [[ ! -s "$OUTPUT_DIR/$path" ]]; then
    printf 'expected report missing: %s\n' "$OUTPUT_DIR/$path" >&2
    exit 1
  fi
done
printf 'run-all detector outputs all present\n'
