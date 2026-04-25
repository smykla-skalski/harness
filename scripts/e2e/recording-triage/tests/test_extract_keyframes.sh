#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/recording-triage/tests/lib-test.sh
. "$SCRIPT_DIR/lib-test.sh"

recording_triage_test_skip_unless_ffmpeg
REPO_ROOT="$(recording_triage_test_repo_root)"
BUILD_FIXTURE="$REPO_ROOT/scripts/e2e/recording-triage/build-fixture.sh"
EXTRACT="$REPO_ROOT/scripts/e2e/recording-triage/extract-keyframes.sh"

WORK_DIR="$(recording_triage_test_make_run_dir extract)"
trap 'rm -rf "$WORK_DIR"' EXIT

FIXTURE_DIR="$WORK_DIR/fixtures"
"$BUILD_FIXTURE" "$FIXTURE_DIR" >/dev/null
RUN_DIR="$WORK_DIR/run"
recording_triage_test_seed_run "$RUN_DIR" "$FIXTURE_DIR/transition.mov"

"$EXTRACT" --run "$RUN_DIR" --timestamp act1=0.020 --timestamp act2=0.140 >/dev/null

MANIFEST="$RUN_DIR/recording-triage/keyframes.json"
if [[ ! -s "$MANIFEST" ]]; then
  printf 'keyframes manifest missing: %s\n' "$MANIFEST" >&2
  exit 1
fi
count="$(jq 'length' "$MANIFEST")"
if [[ "$count" != "2" ]]; then
  printf 'expected 2 keyframe manifest entries, got %s\n' "$count" >&2
  exit 1
fi
for name in act1 act2; do
  png="$RUN_DIR/recording-triage/keyframes/${name}.png"
  if [[ ! -s "$png" ]]; then
    printf 'expected keyframe missing: %s\n' "$png" >&2
    exit 1
  fi
done
printf 'extract-keyframes test ok\n'
