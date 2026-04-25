#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/e2e/triage-run.sh"

fail() {
  printf 'test-e2e-triage-run: %s\n' "$*" >&2
  exit 1
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/e2e-triage-run-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

artifacts_dir="$tmp_dir/artifacts"
findings_file="$tmp_dir/findings/2026-04-25T14-20-00Z-swarm.md"
state_root="$tmp_dir/state-root"
sync_root="$tmp_dir/sync-root"
daemon_log="$tmp_dir/daemon.log"
test_log="$tmp_dir/test.log"
recording_path="$artifacts_dir/swarm-full-flow.mov"
mkdir -p "$state_root/data-home" "$sync_root" "$artifacts_dir" "$(dirname -- "$findings_file")"
printf 'state-root-ok\n' >"$state_root/state.txt"
printf 'sync-root-ok\n' >"$sync_root/act1.ready"
printf 'daemon-log\n' >"$daemon_log"
printf 'test-log\n' >"$test_log"
printf 'video-bytes\n' >"$recording_path"
mkdir -p "$artifacts_dir/ui-snapshots"
printf 'png-bytes\n' >"$artifacts_dir/ui-snapshots/act1.png"
printf 'hierarchy\n' >"$artifacts_dir/ui-snapshots/act1.txt"

"$SCRIPT" \
  --scenario swarm-full-flow \
  --run-id run-123 \
  --artifacts-dir "$artifacts_dir" \
  --findings-file "$findings_file" \
  --exit-code 17 \
  --status failed \
  --started-at 2026-04-25T14:19:00Z \
  --ended-at 2026-04-25T14:20:00Z \
  --duration-seconds 60 \
  --session-id sess-e2e-swarm-run-123 \
  --state-root "$state_root" \
  --sync-root "$sync_root" \
  --recording "$recording_path" \
  --log "$daemon_log" \
  --log "$test_log"

[[ -f "$artifacts_dir/manifest.json" ]] || fail "missing manifest"
[[ -f "$findings_file" ]] || fail "missing findings file"
[[ -f "$artifacts_dir/context/state-root/state.txt" ]] || fail "missing copied state root"
[[ -f "$artifacts_dir/context/sync-root/act1.ready" ]] || fail "missing copied sync root"
[[ -f "$artifacts_dir/logs/daemon.log" ]] || fail "missing copied daemon log"
[[ -f "$artifacts_dir/logs/test.log" ]] || fail "missing copied test log"
grep -Fq 'Mandatory review checklist' "$findings_file" || fail "missing mandatory review checklist"
grep -Fq 'Pending triage.' "$findings_file" || fail "missing pending triage placeholders"
jq -e '
  .scenario == "swarm-full-flow"
  and .run_id == "run-123"
  and .status == "failed"
  and .exit_code == 17
  and .manual_triage_required == true
  and .triage_status == "pending"
  and .automatic_summary.recording_present == true
  and .automatic_summary.ui_snapshot_png_count == "1"
' "$artifacts_dir/manifest.json" >/dev/null || fail "manifest fields did not match expected values"

missing_artifacts_dir="$tmp_dir/missing-artifacts"
missing_findings_file="$tmp_dir/findings/2026-04-25T14-30-00Z-missing.md"
mkdir -p "$missing_artifacts_dir/ui-snapshots"
printf 'png-bytes\n' >"$missing_artifacts_dir/ui-snapshots/act1.png"

set +e
"$SCRIPT" \
  --scenario swarm-full-flow \
  --run-id run-456 \
  --artifacts-dir "$missing_artifacts_dir" \
  --findings-file "$missing_findings_file" \
  --exit-code 0 \
  --status passed \
  --started-at 2026-04-25T14:29:00Z \
  --ended-at 2026-04-25T14:30:00Z \
  --duration-seconds 60 \
  --recording "$missing_artifacts_dir/missing.mov" \
  --log "$daemon_log"
status=$?
set -e

[[ "$status" -ne 0 ]] || fail "expected missing recording to fail successful run triage"
[[ -f "$missing_artifacts_dir/manifest.json" ]] || fail "missing manifest for failed triage collection"
jq -e --arg missing "$missing_artifacts_dir/missing.mov" '
  .status == "passed"
  and (.warnings | any(. == ("missing or empty screen recording: " + $missing)))
' "$missing_artifacts_dir/manifest.json" >/dev/null || fail "missing recording warning not captured"
