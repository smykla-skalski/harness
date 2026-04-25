#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/recording-triage/tests/lib-test.sh
. "$SCRIPT_DIR/lib-test.sh"

recording_triage_test_skip_unless_ffmpeg
REPO_ROOT="$(recording_triage_test_repo_root)"
recording_triage_test_skip_unless_binary "$REPO_ROOT"
BUILD_FIXTURE="$REPO_ROOT/scripts/e2e/recording-triage/build-fixture.sh"
WRAPPER="$REPO_ROOT/scripts/e2e/recording-triage/auto-keyframes.sh"

WORK_DIR="$(recording_triage_test_make_run_dir autokey)"
trap 'rm -rf "$WORK_DIR"' EXIT

FIXTURE_DIR="$WORK_DIR/fixtures"
"$BUILD_FIXTURE" "$FIXTURE_DIR" >/dev/null

RUN_DIR="$WORK_DIR/run"
MARKER_DIR="$RUN_DIR/context/sync-root/e2e-sync"
LOGS_DIR="$RUN_DIR/logs"
SNAPSHOTS_DIR="$RUN_DIR/ui-snapshots"
mkdir -p "$MARKER_DIR" "$LOGS_DIR" "$SNAPSHOTS_DIR"
cp "$FIXTURE_DIR/tiny.mov" "$RUN_DIR/swarm-full-flow.mov"

cat >"$RUN_DIR/screen-recording.log" <<'EOM'
2026-04-25T10:00:00Z using-display id=1 size=2056x1329
2026-04-25T10:00:00Z recording-started
2026-04-25T10:00:00Z recording-ready output=swarm-full-flow.mov
EOM

cat >"$LOGS_DIR/daemon.log" <<'EOM'
2026-04-25T09:59:59.500000+00:00  INFO daemon starting
EOM

# tiny.mov is 0.2s long; pick mtimes inside the window.
touch -d '2026-04-25T10:00:00.040Z' "$MARKER_DIR/act1.ready"
touch -d '2026-04-25T10:00:00.140Z' "$MARKER_DIR/act2.ready"

# Ground-truth snapshots reuse a frame from the same recording so distance is
# small/zero.
ffmpeg -y -loglevel error -ss 0.040 -i "$RUN_DIR/swarm-full-flow.mov" \
  -frames:v 1 "$SNAPSHOTS_DIR/swarm-act1.png"
ffmpeg -y -loglevel error -ss 0.140 -i "$RUN_DIR/swarm-full-flow.mov" \
  -frames:v 1 "$SNAPSHOTS_DIR/swarm-act2.png"

"$WRAPPER" --run "$RUN_DIR" >/dev/null

REPORT="$RUN_DIR/recording-triage/auto-keyframes.json"
KEYFRAMES_MANIFEST="$RUN_DIR/recording-triage/keyframes.json"
COMPARE_REPORT="$RUN_DIR/recording-triage/compare-keyframes.json"

for required in "$REPORT" "$KEYFRAMES_MANIFEST" "$COMPARE_REPORT"; do
  if [[ ! -s "$required" ]]; then
    printf 'expected output missing: %s\n' "$required" >&2
    exit 1
  fi
done

acts="$(jq '.acts | length' "$REPORT")"
if (( acts != 2 )); then
  printf 'expected 2 acts in summary, got %s\n' "$acts" >&2
  exit 1
fi

first_name="$(jq -r '.acts[0].name' "$REPORT")"
if [[ "$first_name" != "swarm-act1" ]]; then
  printf 'expected first act name swarm-act1, got %s\n' "$first_name" >&2
  exit 1
fi

frame_count="$(jq 'length' "$KEYFRAMES_MANIFEST")"
if (( frame_count != 2 )); then
  printf 'expected 2 keyframes manifest entries, got %s\n' "$frame_count" >&2
  exit 1
fi

printf 'auto-keyframes test ok (acts=%s)\n' "$acts"
