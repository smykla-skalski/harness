#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/recording-triage/tests/lib-test.sh
. "$SCRIPT_DIR/lib-test.sh"

recording_triage_test_skip_unless_ffmpeg
REPO_ROOT="$(recording_triage_test_repo_root)"
BUILD_FIXTURE="$REPO_ROOT/scripts/e2e/recording-triage/build-fixture.sh"
ASSERT_RECORDING="$REPO_ROOT/scripts/e2e/recording-triage/assert-recording.sh"

WORK_DIR="$(recording_triage_test_make_run_dir assert)"
trap 'rm -rf "$WORK_DIR"' EXIT

FIXTURE_DIR="$WORK_DIR/fixtures"
"$BUILD_FIXTURE" "$FIXTURE_DIR" >/dev/null

RUN_DIR="$WORK_DIR/run"
recording_triage_test_seed_run "$RUN_DIR" "$FIXTURE_DIR/tiny.mov"

# Default thresholds reject the tiny fixture (< 5 MB).
if "$ASSERT_RECORDING" --run "$RUN_DIR" >/dev/null 2>&1; then
  printf 'expected default assert-recording to reject tiny.mov\n' >&2
  exit 1
fi

# Lowering --min-size accepts the tiny fixture and emits the ok report.
"$ASSERT_RECORDING" --run "$RUN_DIR" --min-size 1 >/dev/null
REPORT="$RUN_DIR/recording-triage/assert-recording.json"
if [[ ! -s "$REPORT" ]]; then
  printf 'assert-recording.json missing: %s\n' "$REPORT" >&2
  exit 1
fi
status="$(jq -r .status "$REPORT")"
if [[ "$status" != "ok" ]]; then
  printf 'expected status=ok, got %s\n' "$status" >&2
  exit 1
fi
printf 'assert-recording test ok\n'
