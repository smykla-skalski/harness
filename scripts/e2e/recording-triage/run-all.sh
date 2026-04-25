#!/usr/bin/env bash
set -euo pipefail

# Run every universal recording-triage detector against a triage run dir and
# aggregate the JSON outputs into recording-triage/summary.json. Detectors that
# need additional inputs (compare-keyframes, layout-drift) are opt-in and
# invoked separately by the skill body.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/lib.sh
. "$SCRIPT_DIR/../lib.sh"
# shellcheck source=scripts/e2e/recording-triage/lib-recording-triage.sh
. "$SCRIPT_DIR/lib-recording-triage.sh"

usage() {
  cat <<'EOF' >&2
usage: run-all.sh <run-dir>
  <run-dir>   triage run dir produced by triage-run.sh
              (e.g. _artifacts/runs/<slug>)
EOF
  exit 64
}

RUN_DIR="${1:-}"
recording_triage_require_run_dir "$RUN_DIR"

OUTPUT_DIR="$(recording_triage_output_dir "$RUN_DIR")"
mkdir -p "$OUTPUT_DIR"
SUMMARY="$OUTPUT_DIR/summary.json"

run_step() {
  local label="$1"; shift
  printf '== %s\n' "$label"
  "$@"
}

run_step "assert-recording" "$SCRIPT_DIR/assert-recording.sh" --run "$RUN_DIR"
run_step "frame-gaps" "$SCRIPT_DIR/frame-gaps.sh" --run "$RUN_DIR"
run_step "dead-head-tail" "$SCRIPT_DIR/detect-dead-head-tail.sh" --run "$RUN_DIR"
run_step "thrash" "$SCRIPT_DIR/detect-thrash.sh" --run "$RUN_DIR"
run_step "auto-keyframes" "$SCRIPT_DIR/auto-keyframes.sh" --run "$RUN_DIR"
run_step "black-frames" "$SCRIPT_DIR/detect-black-frames.sh" --run "$RUN_DIR"
run_step "act-timing" "$SCRIPT_DIR/act-timing.sh" --run "$RUN_DIR"
run_step "act-identifiers" "$SCRIPT_DIR/assert-act-identifiers.sh" --run "$RUN_DIR"
run_step "compare-layout" "$SCRIPT_DIR/compare-layout.sh" --run "$RUN_DIR"
run_step "launch-args" "$SCRIPT_DIR/assert-launch-args.sh" --run "$RUN_DIR"
run_step "emit-checklist" "$SCRIPT_DIR/emit-checklist.sh" --run "$RUN_DIR"

read_json() {
  local path="$1"
  if [[ -s "$path" ]]; then
    cat "$path"
  else
    printf 'null'
  fi
}

read_text() {
  local path="$1"
  if [[ -s "$path" ]]; then
    jq -Rs '.' <"$path"
  else
    printf 'null'
  fi
}

jq -n \
  --argjson assert "$(read_json "$OUTPUT_DIR/assert-recording.json")" \
  --argjson frame_gaps "$(read_json "$OUTPUT_DIR/frame-gaps.json")" \
  --argjson dead_head_tail "$(read_json "$OUTPUT_DIR/dead-head-tail.json")" \
  --argjson thrash "$(read_json "$OUTPUT_DIR/thrash.json")" \
  --argjson black_frames "$(read_json "$OUTPUT_DIR/black-frames.json")" \
  --argjson act_timing "$(read_json "$OUTPUT_DIR/act-timing.json")" \
  --argjson act_identifiers "$(read_json "$OUTPUT_DIR/act-identifiers.json")" \
  --argjson auto_keyframes "$(read_json "$OUTPUT_DIR/auto-keyframes.json")" \
  --argjson layout_drift "$(read_json "$OUTPUT_DIR/layout-drift.json")" \
  --argjson launch_args "$(read_json "$OUTPUT_DIR/launch-args.json")" \
  --argjson checklist "$(read_text "$OUTPUT_DIR/checklist.md")" \
  --arg generated_at "$(e2e_timestamp_utc)" \
  '{
    generated_at: $generated_at,
    assert_recording: $assert,
    frame_gaps: $frame_gaps,
    dead_head_tail: $dead_head_tail,
    thrash: $thrash,
    black_frames: $black_frames,
    act_timing: $act_timing,
    act_identifiers: $act_identifiers,
    auto_keyframes: $auto_keyframes,
    layout_drift: $layout_drift,
    launch_args: $launch_args,
    checklist_markdown: $checklist
  }' >"$SUMMARY"

printf 'recording-triage summary -> %s\n' "$SUMMARY"
