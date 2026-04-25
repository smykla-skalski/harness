#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"

fail() {
  printf 'test-e2e-swarm-contract: %s\n' "$*" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -f "$ROOT/$path" ]] || fail "missing required file: $path"
}

require_text() {
  local path="$1"
  local text="$2"
  grep -Fq -- "$text" "$ROOT/$path" || fail "missing '$text' in $path"
}

require_no_text() {
  local path="$1"
  local text="$2"
  if grep -Fq -- "$text" "$ROOT/$path"; then
    fail "unexpected '$text' in $path"
  fi
}

require_count() {
  local path="$1"
  local text="$2"
  local expected="$3"
  local actual
  actual="$(grep -Fc -- "$text" "$ROOT/$path")"
  [[ "$actual" == "$expected" ]] || fail "expected '$text' to appear $expected times in $path, found $actual"
}

require_mise_task() {
  local task="$1"
  require_text ".mise.toml" "[tasks.\"$task\"]"
}

require_file "scripts/e2e/lib.sh"
require_file "scripts/e2e/probe-runtimes.sh"
require_file "scripts/e2e/seed-session-state.sh"
require_file "scripts/e2e/inject-heuristic-log.sh"
require_file "scripts/e2e/append-gap.sh"
require_file "scripts/e2e/gaps-open-count.sh"
require_file "scripts/e2e/swarm-full-flow.sh"
require_file "scripts/e2e/triage-run.sh"
require_file "docs/e2e/swarm-gaps.md"
require_file "apps/harness-monitor-macos/Scripts/test-swarm-e2e.sh"
require_file "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmFullFlowOrchestrator.swift"
require_file "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmHeuristicInjection.swift"
require_file "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmRuntimeProbe.swift"
require_file "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmSeedState.swift"
require_file "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmRunLayout.swift"
require_file "apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/SwarmFixture.swift"
require_file "apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport/HarnessMonitorUITestAccessibility.swift"
require_file "tests/integration/commands/session/swarm_full_flow.rs"

require_mise_task "e2e:swarm:full"
require_mise_task "e2e:swarm:inject-heuristic"
require_mise_task "e2e:swarm:seed"
require_mise_task "e2e:swarm:probe-runtimes"
require_mise_task "e2e:swarm:gaps-open"
require_mise_task "monitor:macos:test:swarm-e2e"

require_text ".mise.toml" 'harness-monitor-e2e swarm-full-flow --assert'
require_text ".mise.toml" 'harness-monitor-e2e inject-heuristic'
require_text ".mise.toml" 'harness-monitor-e2e seed-session-state'
require_text ".mise.toml" 'harness-monitor-e2e probe-runtimes'
require_text "scripts/e2e/lib.sh" "portable_timeout()"
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/harness-monitor-e2e/main.swift" "SwarmFullFlow.self"
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/harness-monitor-e2e/main.swift" "SeedSessionState.self"
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/harness-monitor-e2e/main.swift" "ProbeRuntimes.self"
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmRuntimeProbe.swift" '"required_missing"'
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmRuntimeProbe.swift" '"claude"'
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmRuntimeProbe.swift" '"codex"'
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmRuntimeProbe.swift" "claude auth status"
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmHeuristicInjection.swift" ".agent_id"
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmHeuristicInjection.swift" "raw.jsonl"
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmFullFlowOrchestrator.swift" "actReady"
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmFullFlowOrchestrator.swift" "actAck"
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmRunLayout.swift" "sess-e2e-swarm-"
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmFullFlowOrchestrator.swift" "session task arbitrate"
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmFullFlowOrchestrator.swift" "observe doctor --json"
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmFullFlowOrchestrator.swift" 'Scripts/generate.sh'
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmFullFlowOrchestrator.swift" "HarnessMonitor.xcworkspace"
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmFullFlowOrchestrator.swift" 'HARNESS_MONITOR_UI_TEST_ARTIFACTS_DIR'
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmFullFlowOrchestrator.swift" 'start-recording'
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmFullFlowOrchestrator.swift" 'ScreenRecordingStopper'
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmFullFlowOrchestrator.swift" 'triage-run.sh'
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmFullFlowOrchestrator.swift" 'Swarm e2e artifacts recorded at'
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmRunLayout.swift" 'io.harnessmonitor.agents-e2e-tests'
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmRunLayout.swift" 'AGENTS_E2E_RUNNER_CONTAINER_ROOT'
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmRunLayout.swift" "swarm-full-flow.xcresult"
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmRunLayout.swift" "ui-snapshots"
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmRunLayout.swift" "recording-control"
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmRunLayout.swift" "screen-recording.json"
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmFullFlowOrchestrator.swift" 'HARNESS_MONITOR_TEST_RETRY_ITERATIONS'
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmFullFlowOrchestrator.swift" 'HARNESS_MONITOR_UI_TEST_RECORDING_CONTROL_DIR'
require_text "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/ScreenRecorder.swift" 'controlDirectoryURL'
# Single-quoted literals carry the contract text verbatim; SC2016 is not applicable.
# shellcheck disable=SC2016
require_text "scripts/e2e/swarm-full-flow.sh" 'exec "$APP_E2E_TOOL_BINARY" swarm-full-flow "$@"'
# shellcheck disable=SC2016
require_text "scripts/e2e/inject-heuristic-log.sh" 'exec "$APP_E2E_TOOL_BINARY" inject-heuristic "$@"'
# shellcheck disable=SC2016
require_text "scripts/e2e/seed-session-state.sh" 'exec "$APP_E2E_TOOL_BINARY" seed-session-state "$@"'
# shellcheck disable=SC2016
require_text "scripts/e2e/probe-runtimes.sh" 'exec "$APP_E2E_TOOL_BINARY" probe-runtimes "$@"'
require_no_text "scripts/e2e/swarm-full-flow.sh" "session task arbitrate"
require_no_text "scripts/e2e/swarm-full-flow.sh" "observe doctor --json"
require_no_text "scripts/e2e/swarm-full-flow.sh" "screencapture -v -k -D1 -V 1800"
require_no_text "scripts/e2e/inject-heuristic-log.sh" 'raw.jsonl'
require_no_text "scripts/e2e/seed-session-state.sh" 'jq -nc'
require_no_text "scripts/e2e/probe-runtimes.sh" 'claude auth status'
require_text "scripts/e2e/triage-run.sh" '## Mandatory review checklist'
require_text "scripts/e2e/triage-run.sh" '--ui-snapshots-source <path>'
require_text "scripts/e2e/triage-run.sh" 'missing ui snapshots source'
require_text "scripts/e2e/triage-run.sh" 'xcresulttool export attachments'
require_text "scripts/e2e/triage-run.sh" 'missing or empty screen recording'
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/SwarmFixture.swift" "final class SwarmFixture"
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/SwarmFixture.swift" "captureCheckpoint"
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/SwarmRunner.swift" "final class SwarmRunner"
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/SwarmRunner.swift" "func act16"
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/SwarmRunner.swift" "sessionAgentListState"
require_text "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Support/HarnessMonitorAccessibilityIDs.swift" "sessionAgentListState"
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport/HarnessMonitorUITestAccessibility.swift" "sessionAgentListState"
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/SwarmFullFlowTests.swift" "func testSwarmFullFlow()"
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport/HarnessMonitorUITestSupport.swift" "HARNESS_MONITOR_UI_TEST_ARTIFACTS_DIR"
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport/HarnessMonitorUITestSupport.swift" "failure-final"
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport/HarnessMonitorUITestDiagnosticsSupport.swift" "recordDiagnosticsSnapshot"
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport/HarnessMonitorUITestDiagnosticsSupport.swift" "XCUIScreen.main.screenshot()"
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests.swift" "selectFastModelForTerminal(in: app, runtime: \"codex\")"
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests+Support.swift" "\"codex\": \"GPT-5.3 Codex Spark\""
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests+Support.swift" "\"codex\": \"Low\""
# shellcheck disable=SC2016
require_text "apps/harness-monitor-macos/Scripts/test-swarm-e2e.sh" 'exec "$APP_E2E_TOOL_BINARY" swarm-full-flow --assert "$@"'
require_text "tests/integration/commands/session/swarm_full_flow.rs" "#[ignore"
require_text "tests/integration/commands/session/mod.rs" "mod swarm_full_flow;"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
project_dir="$tmp_dir/project"
data_home="$tmp_dir/data-home"
mkdir -p "$project_dir"

inject_output="$(
  "$ROOT/scripts/e2e/inject-heuristic-log.sh" \
    --agent "agent-1" \
    --code "python_traceback_output" \
    --runtime "codex" \
    --runtime-session-id "runtime-session-1" \
    --project-dir "$project_dir" \
    --data-home "$data_home"
)"
log_path="$(printf '%s\n' "$inject_output" | jq -er '.log_path')"
[[ -f "$log_path" ]] || fail "injector did not write log file: $log_path"
jq -s -e '
  length == 2
  and .[0].timestamp != null
  and .[0].message.role == "assistant"
  and .[0].message.content[0].type == "tool_use"
  and .[1].message.role == "user"
  and .[1].message.content[0].type == "tool_result"
  and (.[1].message.content[0].content[0].text | contains("Traceback"))
' "$log_path" >/dev/null || fail "injector must emit canonical transcript JSONL"

open_count="$("$ROOT/scripts/e2e/gaps-open-count.sh")"
[[ "$open_count" == "0" ]] || fail "expected zero open e2e gaps, got $open_count"
