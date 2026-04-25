#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/recording-triage/tests/lib-test.sh
. "$SCRIPT_DIR/lib-test.sh"

REPO_ROOT="$(recording_triage_test_repo_root)"
recording_triage_test_skip_unless_binary "$REPO_ROOT"
ASSERT="$REPO_ROOT/scripts/e2e/recording-triage/assert-act-identifiers.sh"

WORK_DIR="$(recording_triage_test_make_run_dir actids)"
trap 'rm -rf "$WORK_DIR"' EXIT

RUN_DIR="$WORK_DIR/run"
MARKER_DIR="$RUN_DIR/context/sync-root/e2e-sync"
SNAPSHOT_DIR="$RUN_DIR/ui-snapshots"
mkdir -p "$MARKER_DIR" "$SNAPSHOT_DIR"

cat >"$MARKER_DIR/act1.ready" <<'EOM'
act=act1
session_id=sess-foo
leader_id=claude-1
EOM

cat >"$SNAPSHOT_DIR/swarm-act1.txt" <<'EOM'
Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.toolbar.chrome.state', label: 'windowTitle=Cockpit'
Cell, 0x2, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.sidebar.session.sess-foo', Selected
Other, 0x3, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.toolbar.connection-badge', label: 'Connection: WS, latency 0 milliseconds'
EOM

"$ASSERT" --run "$RUN_DIR" >/dev/null
REPORT="$RUN_DIR/recording-triage/act-identifiers.json"
if [[ ! -s "$REPORT" ]]; then
  printf 'act-identifiers.json missing: %s\n' "$REPORT" >&2
  exit 1
fi
per_act_count="$(jq '.perAct | length' "$REPORT")"
if (( per_act_count != 1 )); then
  printf 'expected 1 per-act entry, got %s\n' "$per_act_count" >&2
  exit 1
fi
cockpit_verdict="$(jq -r '.perAct[0].findings[] | select(.id == "swarm.act1.cockpit") | .verdict' "$REPORT")"
if [[ "$cockpit_verdict" != "found" ]]; then
  printf 'expected swarm.act1.cockpit verdict found; got %s\n' "$cockpit_verdict" >&2
  exit 1
fi
printf 'assert-act-identifiers test ok (perAct=%s)\n' "$per_act_count"
