#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/lib.sh
. "$SCRIPT_DIR/lib.sh"

SCENARIO=""
RUN_ID=""
ARTIFACTS_DIR=""
FINDINGS_FILE=""
EXIT_CODE=""
STATUS=""
STARTED_AT=""
ENDED_AT=""
DURATION_SECONDS=""
SESSION_ID=""
STATE_ROOT=""
SYNC_ROOT=""
RESULT_BUNDLE=""
RECORDING_PATH=""
declare -a LOG_PATHS=()
declare -a WARNINGS=()

usage() {
  cat <<'EOF' >&2
usage: triage-run.sh \
  --scenario <name> \
  --run-id <id> \
  --artifacts-dir <path> \
  --findings-file <path> \
  --exit-code <status> \
  [--status passed|failed] \
  [--started-at <utc>] \
  [--ended-at <utc>] \
  [--duration-seconds <seconds>] \
  [--session-id <id>] \
  [--state-root <path>] \
  [--sync-root <path>] \
  [--result-bundle <path>] \
  [--recording <path>] \
  [--log <path>]...
EOF
  exit 64
}

note_warning() {
  WARNINGS+=("$1")
}

json_array() {
  if [[ "$#" -eq 0 ]]; then
    printf '[]'
    return
  fi

  printf '%s\n' "$@" | jq -R . | jq -s .
}

copy_path_if_exists() {
  local source="$1"
  local destination="$2"
  if [[ ! -e "$source" ]]; then
    return 1
  fi

  rm -rf "$destination"
  mkdir -p "$(dirname -- "$destination")"
  if [[ -d "$source" ]]; then
    cp -R "$source" "$destination"
  else
    cp -f "$source" "$destination"
  fi
}

require_arg() {
  local flag="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    printf 'missing required argument: --%s\n' "$flag" >&2
    usage
  fi
}

while (($#)); do
  case "$1" in
    --scenario) SCENARIO="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --artifacts-dir) ARTIFACTS_DIR="$2"; shift 2 ;;
    --findings-file) FINDINGS_FILE="$2"; shift 2 ;;
    --exit-code) EXIT_CODE="$2"; shift 2 ;;
    --status) STATUS="$2"; shift 2 ;;
    --started-at) STARTED_AT="$2"; shift 2 ;;
    --ended-at) ENDED_AT="$2"; shift 2 ;;
    --duration-seconds) DURATION_SECONDS="$2"; shift 2 ;;
    --session-id) SESSION_ID="$2"; shift 2 ;;
    --state-root) STATE_ROOT="$2"; shift 2 ;;
    --sync-root) SYNC_ROOT="$2"; shift 2 ;;
    --result-bundle) RESULT_BUNDLE="$2"; shift 2 ;;
    --recording) RECORDING_PATH="$2"; shift 2 ;;
    --log) LOG_PATHS+=("$2"); shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

require_arg "scenario" "$SCENARIO"
require_arg "run-id" "$RUN_ID"
require_arg "artifacts-dir" "$ARTIFACTS_DIR"
require_arg "findings-file" "$FINDINGS_FILE"
require_arg "exit-code" "$EXIT_CODE"

e2e_require_command jq
ENDED_AT="${ENDED_AT:-$(e2e_timestamp_utc)}"
if [[ -z "$STATUS" ]]; then
  if [[ "$EXIT_CODE" == "0" ]]; then
    STATUS="passed"
  else
    STATUS="failed"
  fi
fi
if [[ -z "$DURATION_SECONDS" ]]; then
  DURATION_SECONDS="0"
fi

mkdir -p "$ARTIFACTS_DIR" "$(dirname -- "$FINDINGS_FILE")"

CONTEXT_DIR="$ARTIFACTS_DIR/context"
LOGS_DIR="$ARTIFACTS_DIR/logs"
XCRESULT_EXPORT_DIR="$ARTIFACTS_DIR/xcresult-export"
UI_SNAPSHOTS_DIR="$ARTIFACTS_DIR/ui-snapshots"
mkdir -p "$CONTEXT_DIR" "$LOGS_DIR"

declare -a COPIED_CONTEXT_PATHS=()
declare -a LOCAL_LOG_PATHS=()

for log_path in "${LOG_PATHS[@]}"; do
  if [[ ! -e "$log_path" ]]; then
    note_warning "missing log file: $log_path"
    continue
  fi

  local_destination="$log_path"
  if [[ "$log_path" != "$ARTIFACTS_DIR"/* ]]; then
    local_destination="$LOGS_DIR/$(basename -- "$log_path")"
    copy_path_if_exists "$log_path" "$local_destination"
  fi
  LOCAL_LOG_PATHS+=("$local_destination")
done

if [[ -n "$STATE_ROOT" ]]; then
  if copy_path_if_exists "$STATE_ROOT" "$CONTEXT_DIR/state-root"; then
    COPIED_CONTEXT_PATHS+=("$CONTEXT_DIR/state-root")
  else
    note_warning "missing state root: $STATE_ROOT"
  fi
fi

if [[ -n "$SYNC_ROOT" ]]; then
  if copy_path_if_exists "$SYNC_ROOT" "$CONTEXT_DIR/sync-root"; then
    COPIED_CONTEXT_PATHS+=("$CONTEXT_DIR/sync-root")
  else
    note_warning "missing sync root: $SYNC_ROOT"
  fi
fi

TEST_RESULT="unavailable"
TOTAL_TEST_COUNT="n/a"
PASSED_TESTS="n/a"
FAILED_TESTS="n/a"
SKIPPED_TESTS="n/a"
BUILD_STATUS="unavailable"
BUILD_ERROR_COUNT="n/a"
BUILD_WARNING_COUNT="n/a"

if [[ -n "$RESULT_BUNDLE" ]]; then
  if [[ -d "$RESULT_BUNDLE" ]]; then
    mkdir -p "$XCRESULT_EXPORT_DIR"

    if ! xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" --compact \
      >"$XCRESULT_EXPORT_DIR/test-summary.json"
    then
      note_warning "xcresult test summary export failed: $RESULT_BUNDLE"
    elif command -v jq >/dev/null 2>&1; then
      TEST_RESULT="$(jq -r '.result // "unknown"' "$XCRESULT_EXPORT_DIR/test-summary.json")"
      TOTAL_TEST_COUNT="$(jq -r '.totalTestCount // "n/a"' "$XCRESULT_EXPORT_DIR/test-summary.json")"
      PASSED_TESTS="$(jq -r '.passedTests // "n/a"' "$XCRESULT_EXPORT_DIR/test-summary.json")"
      FAILED_TESTS="$(jq -r '.failedTests // "n/a"' "$XCRESULT_EXPORT_DIR/test-summary.json")"
      SKIPPED_TESTS="$(jq -r '.skippedTests // "n/a"' "$XCRESULT_EXPORT_DIR/test-summary.json")"
    fi

    if ! xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" --compact \
      >"$XCRESULT_EXPORT_DIR/tests.json"
    then
      note_warning "xcresult detailed test export failed: $RESULT_BUNDLE"
    fi

    if ! xcrun xcresulttool get build-results --path "$RESULT_BUNDLE" --compact \
      >"$XCRESULT_EXPORT_DIR/build-results.json"
    then
      note_warning "xcresult build-results export failed: $RESULT_BUNDLE"
    elif command -v jq >/dev/null 2>&1; then
      BUILD_STATUS="$(jq -r '.status // "unknown"' "$XCRESULT_EXPORT_DIR/build-results.json")"
      BUILD_ERROR_COUNT="$(jq -r '.errorCount // "n/a"' "$XCRESULT_EXPORT_DIR/build-results.json")"
      BUILD_WARNING_COUNT="$(jq -r '.warningCount // "n/a"' "$XCRESULT_EXPORT_DIR/build-results.json")"
    fi

    if ! xcrun xcresulttool export attachments --path "$RESULT_BUNDLE" \
      --output-path "$XCRESULT_EXPORT_DIR/attachments" >/dev/null 2>&1
    then
      note_warning "xcresult attachment export failed: $RESULT_BUNDLE"
    fi

    if ! xcrun xcresulttool export diagnostics --path "$RESULT_BUNDLE" \
      --output-path "$XCRESULT_EXPORT_DIR/diagnostics" >/dev/null 2>&1
    then
      note_warning "xcresult diagnostics export failed: $RESULT_BUNDLE"
    fi
  else
    note_warning "missing xcresult bundle: $RESULT_BUNDLE"
  fi
fi

SNAPSHOT_PNG_COUNT="0"
SNAPSHOT_TXT_COUNT="0"
if [[ -d "$UI_SNAPSHOTS_DIR" ]]; then
  SNAPSHOT_PNG_COUNT="$(find "$UI_SNAPSHOTS_DIR" -name '*.png' -type f | wc -l | tr -d ' ')"
  SNAPSHOT_TXT_COUNT="$(find "$UI_SNAPSHOTS_DIR" -name '*.txt' -type f | wc -l | tr -d ' ')"
fi

RECORDING_PRESENT=false
if [[ -n "$RECORDING_PATH" && -s "$RECORDING_PATH" ]]; then
  RECORDING_PRESENT=true
else
  note_warning "missing or empty screen recording: ${RECORDING_PATH:-<unset>}"
fi

final_status=0
if [[ "$EXIT_CODE" == "0" && "$RECORDING_PRESENT" != true ]]; then
  final_status=1
fi
if [[ "$EXIT_CODE" == "0" && "$SNAPSHOT_PNG_COUNT" == "0" ]]; then
  note_warning "successful run did not export any UI snapshot PNGs"
  final_status=1
fi
if [[ "$EXIT_CODE" == "0" && -n "$RESULT_BUNDLE" && ! -d "$RESULT_BUNDLE" ]]; then
  note_warning "successful run did not retain an xcresult bundle"
  final_status=1
fi

warnings_json='[]'
context_json='[]'
logs_json='[]'
if [[ "${#WARNINGS[@]}" -gt 0 ]]; then
  warnings_json="$(json_array "${WARNINGS[@]}")"
fi
if [[ "${#COPIED_CONTEXT_PATHS[@]}" -gt 0 ]]; then
  context_json="$(json_array "${COPIED_CONTEXT_PATHS[@]}")"
fi
if [[ "${#LOCAL_LOG_PATHS[@]}" -gt 0 ]]; then
  logs_json="$(json_array "${LOCAL_LOG_PATHS[@]}")"
fi

jq -n \
  --arg scenario "$SCENARIO" \
  --arg run_id "$RUN_ID" \
  --arg status "$STATUS" \
  --arg session_id "$SESSION_ID" \
  --arg started_at "$STARTED_AT" \
  --arg ended_at "$ENDED_AT" \
  --arg artifacts_dir "$ARTIFACTS_DIR" \
  --arg findings_file "$FINDINGS_FILE" \
  --arg result_bundle "$RESULT_BUNDLE" \
  --arg recording_path "$RECORDING_PATH" \
  --arg test_result "$TEST_RESULT" \
  --arg total_test_count "$TOTAL_TEST_COUNT" \
  --arg passed_tests "$PASSED_TESTS" \
  --arg failed_tests "$FAILED_TESTS" \
  --arg skipped_tests "$SKIPPED_TESTS" \
  --arg build_status "$BUILD_STATUS" \
  --arg build_error_count "$BUILD_ERROR_COUNT" \
  --arg build_warning_count "$BUILD_WARNING_COUNT" \
  --arg snapshot_png_count "$SNAPSHOT_PNG_COUNT" \
  --arg snapshot_txt_count "$SNAPSHOT_TXT_COUNT" \
  --argjson exit_code "$EXIT_CODE" \
  --argjson duration_seconds "$DURATION_SECONDS" \
  --argjson warnings "$warnings_json" \
  --argjson context_paths "$context_json" \
  --argjson log_paths "$logs_json" \
  --argjson recording_present "$RECORDING_PRESENT" \
  '{
    scenario: $scenario,
    run_id: $run_id,
    status: $status,
    exit_code: $exit_code,
    session_id: (if $session_id == "" then null else $session_id end),
    started_at: (if $started_at == "" then null else $started_at end),
    ended_at: $ended_at,
    duration_seconds: $duration_seconds,
    artifacts_dir: $artifacts_dir,
    findings_file: $findings_file,
    manual_triage_required: true,
    triage_status: "pending",
    artifacts: {
      result_bundle: (if $result_bundle == "" then null else $result_bundle end),
      recording_path: (if $recording_path == "" then null else $recording_path end),
      log_paths: $log_paths,
      copied_context_paths: $context_paths
    },
    automatic_summary: {
      recording_present: $recording_present,
      test_result: $test_result,
      total_test_count: $total_test_count,
      passed_tests: $passed_tests,
      failed_tests: $failed_tests,
      skipped_tests: $skipped_tests,
      build_status: $build_status,
      build_error_count: $build_error_count,
      build_warning_count: $build_warning_count,
      ui_snapshot_png_count: $snapshot_png_count,
      ui_snapshot_text_count: $snapshot_txt_count
    },
    warnings: $warnings
  }' >"$ARTIFACTS_DIR/manifest.json"

{
  printf '# %s e2e triage — %s\n\n' "$SCENARIO" "$ENDED_AT"
  printf -- "- **Run ID:** \`%s\`\n" "$RUN_ID"
  if [[ -n "$SESSION_ID" ]]; then
    printf -- "- **Session ID:** \`%s\`\n" "$SESSION_ID"
  fi
  printf -- "- **Outcome:** \`%s\` (exit \`%s\`)\n" "$STATUS" "$EXIT_CODE"
  if [[ -n "$STARTED_AT" ]]; then
    printf -- "- **Started:** \`%s\`\n" "$STARTED_AT"
  fi
  printf -- "- **Ended:** \`%s\`\n" "$ENDED_AT"
  printf -- "- **Duration:** \`%ss\`\n" "$DURATION_SECONDS"
  printf -- "- **Artifacts:** \`%s\`\n" "$ARTIFACTS_DIR"
  if [[ -n "$RECORDING_PATH" ]]; then
    printf -- "- **Recording:** \`%s\`\n" "$RECORDING_PATH"
  fi
  if [[ -n "$RESULT_BUNDLE" ]]; then
    printf -- "- **XCResult:** \`%s\`\n" "$RESULT_BUNDLE"
  fi
  printf -- "- **Manifest:** \`%s\`\n\n" "$ARTIFACTS_DIR/manifest.json"

  printf '## Automatic summary\n\n'
  printf -- "- Test result: \`%s\`\n" "$TEST_RESULT"
  printf -- "- Tests: total \`%s\`, passed \`%s\`, failed \`%s\`, skipped \`%s\`\n" \
    "$TOTAL_TEST_COUNT" "$PASSED_TESTS" "$FAILED_TESTS" "$SKIPPED_TESTS"
  printf -- "- Build: \`%s\` (errors \`%s\`, warnings \`%s\`)\n" \
    "$BUILD_STATUS" "$BUILD_ERROR_COUNT" "$BUILD_WARNING_COUNT"
  printf -- "- UI snapshots: \`%s\` PNG, \`%s\` hierarchy/text files\n" \
    "$SNAPSHOT_PNG_COUNT" "$SNAPSHOT_TXT_COUNT"
  printf -- "- Recording present: \`%s\`\n\n" "$RECORDING_PRESENT"

  printf '## Mandatory review checklist\n\n'
  printf -- '- [ ] Reviewed the full recording end to end.\n'
  printf -- '- [ ] Reviewed the exported act snapshots and hierarchy captures.\n'
  printf -- '- [ ] Checked for crashes, failed interactions, disabled surfaces, or wrong states.\n'
  printf -- '- [ ] Checked for layout drift, clipped content, jumpy/blinking elements, or unstable values.\n'
  printf -- '- [ ] Checked for readability issues, density/noise, misplaced controls, or visual clutter.\n'
  printf -- '- [ ] Checked for visible slowness, stalls, or unexpected pauses.\n'
  printf -- '- [ ] Captured all confirmed findings below before moving to another e2e task.\n\n'

  printf '## Findings\n\n'
  printf '### Confirmed issues\n'
  printf -- '- Pending triage.\n\n'
  printf '### Notable observations\n'
  printf -- '- Pending triage.\n\n'
  printf '### Follow-up\n'
  printf -- '- Pending triage.\n\n'

  printf '## Artifact inventory\n\n'
  if [[ "${#LOCAL_LOG_PATHS[@]}" -gt 0 ]]; then
    printf '### Logs\n'
    for log_path in "${LOCAL_LOG_PATHS[@]}"; do
      printf -- "- \`%s\`\n" "$log_path"
    done
    printf '\n'
  fi
  if [[ "${#COPIED_CONTEXT_PATHS[@]}" -gt 0 ]]; then
    printf '### Preserved context\n'
    for copied_path in "${COPIED_CONTEXT_PATHS[@]}"; do
      printf -- "- \`%s\`\n" "$copied_path"
    done
    printf '\n'
  fi
  if [[ "${#WARNINGS[@]}" -gt 0 ]]; then
    printf '## Collection warnings\n\n'
    for warning in "${WARNINGS[@]}"; do
      printf -- '- %s\n' "$warning"
    done
  fi
} >"$FINDINGS_FILE"

exit "$final_status"
