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
require_file "docs/e2e/swarm-gaps.md"
require_file "apps/harness-monitor-macos/Scripts/test-swarm-e2e.sh"
require_file "apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/SwarmFixture.swift"
require_file "apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport/HarnessMonitorUITestAccessibility.swift"
require_file "tests/integration/commands/session/swarm_full_flow.rs"

require_mise_task "e2e:swarm-full-flow"
require_mise_task "e2e:swarm-inject-heuristic"
require_mise_task "e2e:swarm-seed"
require_mise_task "e2e:swarm-probe-runtimes"
require_mise_task "e2e:swarm-gaps-open"
require_mise_task "monitor:macos:test:swarm-e2e"

require_text "scripts/e2e/lib.sh" "portable_timeout()"
require_text "scripts/e2e/probe-runtimes.sh" '"required_missing"'
require_text "scripts/e2e/probe-runtimes.sh" '"claude"'
require_text "scripts/e2e/probe-runtimes.sh" '"codex"'
require_text "scripts/e2e/probe-runtimes.sh" "claude auth status"
require_text "scripts/e2e/swarm-full-flow.sh" ".agent_id"
require_text "scripts/e2e/swarm-full-flow.sh" ".task_id"
require_text "scripts/e2e/swarm-full-flow.sh" "act_ready"
require_text "scripts/e2e/swarm-full-flow.sh" "act_ack"
require_text "scripts/e2e/swarm-full-flow.sh" "session task arbitrate"
require_text "scripts/e2e/swarm-full-flow.sh" "observe doctor --json"
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/SwarmFixture.swift" "final class SwarmFixture"
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/SwarmFixture.swift" "func act16"
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/SwarmFixture.swift" "sessionAgentListState"
require_text "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Support/HarnessMonitorAccessibilityIDs.swift" "sessionAgentListState"
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport/HarnessMonitorUITestAccessibility.swift" "sessionAgentListState"
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/SwarmFullFlowTests.swift" "func testSwarmFullFlow()"
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests.swift" "selectFastModelForTerminal(in: app, runtime: \"codex\")"
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests+Support.swift" "\"codex\": \"GPT-5.3 Codex Spark\""
require_text "apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests+Support.swift" "\"codex\": \"Low\""
require_text "apps/harness-monitor-macos/Scripts/test-swarm-e2e.sh" "scripts/e2e/swarm-full-flow.sh"
require_text "tests/integration/commands/session/swarm_full_flow.rs" "#[ignore"
require_text "tests/integration/commands/session/mod.rs" "mod swarm_full_flow;"

open_count="$("$ROOT/scripts/e2e/gaps-open-count.sh")"
[[ "$open_count" == "0" ]] || fail "expected zero open e2e gaps, got $open_count"
