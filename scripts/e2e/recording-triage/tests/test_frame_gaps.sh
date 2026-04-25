#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/recording-triage/tests/lib-test.sh
. "$SCRIPT_DIR/lib-test.sh"

recording_triage_test_skip_unless_ffmpeg
REPO_ROOT="$(recording_triage_test_repo_root)"
recording_triage_test_skip_unless_binary "$REPO_ROOT"
BUILD_FIXTURE="$REPO_ROOT/scripts/e2e/recording-triage/build-fixture.sh"
FRAME_GAPS="$REPO_ROOT/scripts/e2e/recording-triage/frame-gaps.sh"

WORK_DIR="$(recording_triage_test_make_run_dir framegaps)"
trap 'rm -rf "$WORK_DIR"' EXIT

FIXTURE_DIR="$WORK_DIR/fixtures"
"$BUILD_FIXTURE" "$FIXTURE_DIR" >/dev/null
RUN_DIR="$WORK_DIR/run"
recording_triage_test_seed_run "$RUN_DIR" "$FIXTURE_DIR/tiny.mov"

"$FRAME_GAPS" --run "$RUN_DIR" >/dev/null
REPORT="$RUN_DIR/recording-triage/frame-gaps.json"
if [[ ! -s "$REPORT" ]]; then
  printf 'frame-gaps.json missing: %s\n' "$REPORT" >&2
  exit 1
fi
total="$(jq '.totalFrames' "$REPORT")"
if (( total < 1 )); then
  printf 'expected totalFrames > 0, got %s\n' "$total" >&2
  exit 1
fi
printf 'frame-gaps test ok (totalFrames=%s)\n' "$total"
