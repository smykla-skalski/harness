#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/recording-triage/tests/lib-test.sh
. "$SCRIPT_DIR/lib-test.sh"

REPO_ROOT="$(recording_triage_test_repo_root)"
recording_triage_test_skip_unless_binary "$REPO_ROOT"
WRAPPER="$REPO_ROOT/scripts/e2e/recording-triage/act-timing.sh"

WORK_DIR="$(recording_triage_test_make_run_dir acttiming)"
trap 'rm -rf "$WORK_DIR"' EXIT

RUN_DIR="$WORK_DIR/run"
MARKER_DIR="$RUN_DIR/context/sync-root/e2e-sync"
LOGS_DIR="$RUN_DIR/logs"
mkdir -p "$MARKER_DIR" "$LOGS_DIR"

# screen-recording.log: recording-started 5s after daemon launch
cat >"$RUN_DIR/screen-recording.log" <<'EOM'
2026-04-25T10:00:00Z using-display id=1 size=2056x1329
2026-04-25T10:00:05Z recording-started
2026-04-25T10:00:05Z recording-ready output=swarm-full-flow.mov
2026-04-25T10:00:35Z recording-finished output=swarm-full-flow.mov
EOM

# daemon.log: app launch at 10:00:00Z (matches first ISO timestamp on the line)
cat >"$LOGS_DIR/daemon.log" <<'EOM'
2026-04-25T10:00:00.500000+00:00  INFO daemon starting sandboxed=true
2026-04-25T10:00:01.100000+00:00  INFO daemon ready
EOM

# Two markers: act1.ready 10s after recording-started, act2.ready 5s later.
touch -d '2026-04-25T10:00:15Z' "$MARKER_DIR/act1.ready"
touch -d '2026-04-25T10:00:20Z' "$MARKER_DIR/act2.ready"
touch -d '2026-04-25T10:00:15.500000Z' "$MARKER_DIR/act1.ack"
touch -d '2026-04-25T10:00:20.200000Z' "$MARKER_DIR/act2.ack"

"$WRAPPER" --run "$RUN_DIR" >/dev/null
REPORT="$RUN_DIR/recording-triage/act-timing.json"
if [[ ! -s "$REPORT" ]]; then
  printf 'act-timing.json missing: %s\n' "$REPORT" >&2
  exit 1
fi

acts_count="$(jq '.acts | length' "$REPORT")"
if (( acts_count != 2 )); then
  printf 'expected 2 acts, got %s\n' "$acts_count" >&2
  exit 1
fi

ready1="$(jq '.acts[0].readySeconds' "$REPORT")"
# 10:00:15 - 10:00:05 = 10
if [[ "$ready1" != "10" ]] && ! awk "BEGIN{exit !($ready1 >= 9.5 && $ready1 <= 10.5)}"; then
  printf 'expected act1.readySeconds ~= 10, got %s\n' "$ready1" >&2
  exit 1
fi

printf 'act-timing test ok (acts=%s, ready1=%s)\n' "$acts_count" "$ready1"
