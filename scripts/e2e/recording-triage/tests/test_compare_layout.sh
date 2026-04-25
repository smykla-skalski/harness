#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/recording-triage/tests/lib-test.sh
. "$SCRIPT_DIR/lib-test.sh"

REPO_ROOT="$(recording_triage_test_repo_root)"
recording_triage_test_skip_unless_binary "$REPO_ROOT"
COMPARE="$REPO_ROOT/scripts/e2e/recording-triage/compare-layout.sh"

WORK_DIR="$(recording_triage_test_make_run_dir layoutdrift)"
trap 'rm -rf "$WORK_DIR"' EXIT

RUN_DIR="$WORK_DIR/run"
SNAPSHOT_DIR="$RUN_DIR/ui-snapshots"
mkdir -p "$SNAPSHOT_DIR"

cat >"$SNAPSHOT_DIR/swarm-act1.txt" <<'EOM'
Application 'Harness' frame: {{0, 0}, {1280, 820}}
  Window 'main' identifier='mainWindow' frame: {{0, 0}, {1280, 820}}
    Button 'Login' identifier='loginButton' frame: {{100, 200}, {120, 32}}
EOM

cat >"$SNAPSHOT_DIR/swarm-act2.txt" <<'EOM'
Application 'Harness' frame: {{0, 0}, {1280, 820}}
  Window 'main' identifier='mainWindow' frame: {{0, 0}, {1280, 820}}
    Button 'Login' identifier='loginButton' frame: {{160, 240}, {120, 32}}
EOM

cat >"$SNAPSHOT_DIR/swarm-act3.txt" <<'EOM'
Application 'Harness' frame: {{0, 0}, {1280, 820}}
  Window 'main' identifier='mainWindow' frame: {{0, 0}, {1280, 820}}
    Button 'Login' identifier='loginButton' frame: {{160, 240}, {120, 32}}
EOM

"$COMPARE" --run "$RUN_DIR" >/dev/null
REPORT="$RUN_DIR/recording-triage/layout-drift.json"
if [[ ! -s "$REPORT" ]]; then
  printf 'layout-drift.json missing: %s\n' "$REPORT" >&2
  exit 1
fi

pair_count="$(jq '.pairs | length' "$REPORT")"
if (( pair_count != 2 )); then
  printf 'expected 2 pair entries, got %s\n' "$pair_count" >&2
  exit 1
fi

first_drifts="$(jq '.pairs[0].drifts | length' "$REPORT")"
if (( first_drifts != 1 )); then
  printf 'expected 1 drift in first pair, got %s\n' "$first_drifts" >&2
  exit 1
fi

second_drifts="$(jq '.pairs[1].drifts | length' "$REPORT")"
if (( second_drifts != 0 )); then
  printf 'expected 0 drift in second pair, got %s\n' "$second_drifts" >&2
  exit 1
fi

first_before="$(jq -r '.pairs[0].before' "$REPORT")"
first_after="$(jq -r '.pairs[0].after' "$REPORT")"
if [[ "$first_before" != "swarm-act1" || "$first_after" != "swarm-act2" ]]; then
  printf 'expected swarm-act1 -> swarm-act2; got %s -> %s\n' "$first_before" "$first_after" >&2
  exit 1
fi

drift_id="$(jq -r '.pairs[0].drifts[0].identifier' "$REPORT")"
if [[ "$drift_id" != "loginButton" ]]; then
  printf 'expected loginButton drift identifier; got %s\n' "$drift_id" >&2
  exit 1
fi

printf 'compare-layout test ok (pairs=%s, drift0=%s)\n' "$pair_count" "$first_drifts"
