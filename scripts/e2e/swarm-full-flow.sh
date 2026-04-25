#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/lib.sh
. "$SCRIPT_DIR/lib.sh"

ROOT="$(e2e_repo_root)"
APP_ROOT="$ROOT/apps/harness-monitor-macos"
# shellcheck source=scripts/lib/common-repo-root.sh
. "$ROOT/scripts/lib/common-repo-root.sh"
COMMON_REPO_ROOT="$(resolve_common_repo_root "$ROOT")"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/xcodebuild-destination.sh
. "$APP_ROOT/Scripts/lib/xcodebuild-destination.sh"

ASSERT_MODE=0
while (($#)); do
  case "$1" in
    --assert) ASSERT_MODE=1; shift ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

e2e_require_command jq
e2e_require_command python3

RUN_ID="${HARNESS_E2E_RUN_ID:-$(e2e_random_id)}"
STATE_ROOT_PARENT="${HARNESS_E2E_STATE_ROOT_PARENT:-${TMPDIR:-/tmp}/HarnessMonitorSwarmE2E}"
STATE_ROOT="${HARNESS_E2E_STATE_ROOT:-$STATE_ROOT_PARENT/$RUN_ID}"
DATA_ROOT="${HARNESS_E2E_DATA_ROOT:-$STATE_ROOT/data-root}"
DATA_HOME="${HARNESS_E2E_DATA_HOME:-$DATA_ROOT/data-home}"
AGENTS_E2E_TEST_BUNDLE_ID="io.harnessmonitor.agents-e2e-tests"
AGENTS_E2E_RUNNER_BUNDLE_ID="${HARNESS_E2E_RUNNER_BUNDLE_ID:-$AGENTS_E2E_TEST_BUNDLE_ID.xctrunner}"
AGENTS_E2E_RUNNER_CONTAINER_ROOT="${HARNESS_E2E_RUNNER_CONTAINER_ROOT:-$HOME/Library/Containers/$AGENTS_E2E_RUNNER_BUNDLE_ID/Data}"
# The XCTest runner process writes the act acknowledgements and is sandboxed, so
# the cross-process markers must live inside the runner container instead of the
# external daemon data root or the tested app's container.
SYNC_ROOT="${HARNESS_E2E_SYNC_ROOT:-$AGENTS_E2E_RUNNER_CONTAINER_ROOT/tmp/HarnessMonitorSwarmE2E/$RUN_ID}"
SYNC_DIR="$SYNC_ROOT/e2e-sync"
LOG_ROOT="$STATE_ROOT/logs"
DAEMON_LOG="$LOG_ROOT/daemon.log"
ACT_DRIVER_LOG="$LOG_ROOT/act-driver.log"
PROJECT_DIR="${HARNESS_E2E_PROJECT_DIR:-$ROOT}"
SESSION_ID="${HARNESS_E2E_SESSION_ID:-sess-e2e-swarm-$RUN_ID}"
DESTINATION="$(harness_monitor_xcodebuild_destination)"
DERIVED_DATA_PATH="${XCODEBUILD_DERIVED_DATA_PATH:-$COMMON_REPO_ROOT/xcode-derived}"
XCODEBUILD_RUNNER="$APP_ROOT/Scripts/xcodebuild-with-lock.sh"
ONLY_TESTING="${XCODE_ONLY_TESTING:-HarnessMonitorAgentsE2ETests/SwarmFullFlowTests/testSwarmFullFlow}"
HARNESS_BINARY="${HARNESS_E2E_HARNESS_BINARY:-$(e2e_resolve_harness_binary "$ROOT")}"
KEEP_DATA="${HARNESS_E2E_KEEP_DATA:-0}"

DAEMON_PID=""
ACT_DRIVER_PID=""

mkdir -p "$DATA_HOME" "$SYNC_DIR" "$LOG_ROOT"
export HARNESS_DAEMON_DATA_HOME="$DATA_HOME"
export HARNESS_E2E_DATA_HOME="$DATA_HOME"
export HARNESS_E2E_HARNESS_BINARY="$HARNESS_BINARY"
export HARNESS_E2E_PROJECT_DIR="$PROJECT_DIR"
export HARNESS_E2E_SESSION_ID="$SESSION_ID"
export XDG_DATA_HOME="$DATA_HOME"

cleanup() {
  local status="$1"
  if [[ -n "$ACT_DRIVER_PID" ]]; then
    kill "$ACT_DRIVER_PID" 2>/dev/null || true
    wait "$ACT_DRIVER_PID" 2>/dev/null || true
  fi
  if [[ -n "$DAEMON_PID" ]]; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi

  if [[ "$status" -eq 0 && "$KEEP_DATA" != "1" ]]; then
    rm -rf "$SYNC_ROOT"
    rm -rf "$STATE_ROOT"
    return
  fi

  {
    printf 'Swarm e2e state preserved at: %s\n' "$STATE_ROOT"
    printf 'Swarm e2e sync preserved at: %s\n' "$SYNC_ROOT"
    if [[ -f "$DAEMON_LOG" ]]; then
      printf '%s\n' '--- daemon log tail ---'
      tail -n 80 "$DAEMON_LOG"
    fi
    if [[ -f "$ACT_DRIVER_LOG" ]]; then
      printf '%s\n' '--- act driver log tail ---'
      tail -n 120 "$ACT_DRIVER_LOG"
    fi
  } >&2
}

trap 'status=$?; cleanup "$status"; exit "$status"' EXIT

run_harness() {
  XDG_DATA_HOME="$DATA_HOME" HARNESS_DAEMON_DATA_HOME="$DATA_HOME" "$HARNESS_BINARY" "$@"
}

run_harness_may_fail() {
  set +e
  XDG_DATA_HOME="$DATA_HOME" HARNESS_DAEMON_DATA_HOME="$DATA_HOME" "$HARNESS_BINARY" "$@"
  local status=$?
  set -e
  return "$status"
}

run_harness_ignore_failure() {
  run_harness_may_fail "$@" || true
}

wait_for_daemon() {
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    if run_harness daemon status >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  printf 'Timed out waiting for daemon readiness\n' >&2
  return 1
}

act_ready() {
  local act="$1"
  shift
  e2e_write_kv_marker "$SYNC_DIR/$act.ready" "act=$act" "$@"
}

act_ack() {
  local act="$1"
  e2e_wait_for_file "$SYNC_DIR/$act.ack" 120
}

runtime_available() {
  local runtime="$1"
  jq -e --arg runtime "$runtime" '.runtimes[$runtime].available == true' "$STATE_ROOT/probe.json" >/dev/null
}

append_optional_skip() {
  local runtime="$1"
  "$SCRIPT_DIR/append-gap.sh" \
    --id "SKIP-$runtime" \
    --status Closed \
    --severity low \
    --subsystem runtime-probe \
    --current "optional runtime $runtime unavailable in this environment" \
    --desired "optional runtime absence is documented and non-blocking" \
    --closed-by "runtime probe"
}

join_agent() {
  local role="$1"
  local runtime="$2"
  local name="$3"
  local persona="$4"
  local output
  output="$(
    run_harness session join "$SESSION_ID" \
      --project-dir "$PROJECT_DIR" \
      --role "$role" \
      --runtime "$runtime" \
      --name "$name" \
      --persona "$persona"
  )"
  printf '%s\n' "$output" \
    | jq -er --arg name "$name" '.agents[] | select(.name == $name) | .agent_id' \
    | tail -n1
}

create_task() {
  local title="$1"
  local severity="$2"
  run_harness session task create "$SESSION_ID" \
    --project-dir "$PROJECT_DIR" \
    --title "$title" \
    --severity "$severity" \
    --actor "$LEADER_ID" \
    | jq -er '.task_id'
}

assign_and_start() {
  local task_id="$1"
  local agent_id="$2"
  run_harness session task assign "$SESSION_ID" "$task_id" "$agent_id" \
    --project-dir "$PROJECT_DIR" \
    --actor "$LEADER_ID"
  run_harness session task update "$SESSION_ID" "$task_id" \
    --project-dir "$PROJECT_DIR" \
    --status in_progress \
    --actor "$agent_id"
}

submit_request_changes_round() {
  local task_id="$1"
  local worker_id="$2"
  local reviewer_a="$3"
  local reviewer_b="$4"
  local note="$5"
  local points
  points='[{"point_id":"p1","text":"A","state":"open"},{"point_id":"p2","text":"B","state":"open"},{"point_id":"p3","text":"C","state":"open"}]'

  run_harness session task submit-for-review "$SESSION_ID" "$task_id" \
    --project-dir "$PROJECT_DIR" \
    --actor "$worker_id" \
    --summary "ready for review"
  run_harness_ignore_failure session task claim-review "$SESSION_ID" "$task_id" \
    --project-dir "$PROJECT_DIR" \
    --actor "$reviewer_a" >/dev/null
  run_harness_ignore_failure session task claim-review "$SESSION_ID" "$task_id" \
    --project-dir "$PROJECT_DIR" \
    --actor "$reviewer_b" >/dev/null
  run_harness session task submit-review "$SESSION_ID" "$task_id" \
    --project-dir "$PROJECT_DIR" \
    --actor "$reviewer_a" \
    --verdict request_changes \
    --summary "changes requested" \
    --points "$points"
  run_harness session task submit-review "$SESSION_ID" "$task_id" \
    --project-dir "$PROJECT_DIR" \
    --actor "$reviewer_b" \
    --verdict request_changes \
    --summary "changes requested" \
    --points "$points"
  run_harness session task respond-review "$SESSION_ID" "$task_id" \
    --project-dir "$PROJECT_DIR" \
    --actor "$worker_id" \
    --agreed p1 \
    --disputed p2,p3 \
    --note "$note"
}

run_observe_commands() {
  run_harness_ignore_failure observe scan "$SESSION_ID" --json --project-hint "$(basename "$PROJECT_DIR")" >/dev/null
  run_harness_ignore_failure observe watch "$SESSION_ID" --timeout 5 --json --project-hint "$(basename "$PROJECT_DIR")" >/dev/null
  run_harness_ignore_failure observe dump "$SESSION_ID" --raw-json --project-hint "$(basename "$PROJECT_DIR")" >/dev/null
  run_harness observe doctor --json --project-dir "$PROJECT_DIR" >/dev/null
}

run_act_driver() {
  printf 'act driver started\n'

  run_harness session start \
    --project-dir "$PROJECT_DIR" \
    --session-id "$SESSION_ID" \
    --title "swarm" \
    --context "e2e swarm full flow" >/dev/null
  LEADER_ID="$(join_agent leader claude "Swarm Leader" architect)"
  act_ready act1 "session_id=$SESSION_ID" "leader_id=$LEADER_ID"
  act_ack act1

  WORKER_CODEX_ID="$(join_agent worker codex "Swarm Worker Codex" test-writer)"
  WORKER_CLAUDE_ID="$(join_agent worker claude "Swarm Worker Claude" code-reviewer)"
  REVIEWER_CLAUDE_ID="$(join_agent reviewer claude "Swarm Reviewer Claude" code-reviewer)"
  REVIEWER_CODEX_ID="$(join_agent reviewer codex "Swarm Reviewer Codex" code-reviewer)"
  REVIEWER_DUP_CLAUDE_ID="$(join_agent reviewer claude "Swarm Reviewer Claude Duplicate" code-reviewer)"
  OBSERVER_ID="$(join_agent observer claude "Swarm Observer" debugger)"
  IMPROVER_ID="$(join_agent improver codex "Swarm Improver" architect)"
  if runtime_available gemini; then
    join_agent observer gemini "Swarm Observer Gemini" debugger >/dev/null
  else
    append_optional_skip gemini
  fi
  if runtime_available copilot; then
    join_agent improver copilot "Swarm Improver Copilot" architect >/dev/null
  else
    append_optional_skip copilot
  fi
  if runtime_available vibe; then
    VIBE_WORKER_ID="$(join_agent worker vibe "Swarm Worker Vibe" generalist)"
  else
    VIBE_WORKER_ID=""
    append_optional_skip vibe
  fi
  if ! runtime_available opencode; then
    append_optional_skip opencode
  fi
  act_ready act2 \
    "worker_codex_id=$WORKER_CODEX_ID" \
    "worker_claude_id=$WORKER_CLAUDE_ID" \
    "reviewer_claude_id=$REVIEWER_CLAUDE_ID" \
    "reviewer_codex_id=$REVIEWER_CODEX_ID" \
    "observer_id=$OBSERVER_ID" \
    "improver_id=$IMPROVER_ID"
  act_ack act2

  TASK_REVIEW_ID="$(create_task "Review full-flow task" high)"
  TASK_AUTOSPAWN_ID="$(create_task "Auto-spawn reviewer task" medium)"
  TASK_ARBITRATION_ID="$(create_task "Arbitration review task" high)"
  TASK_REFUSAL_ID="$(create_task "Busy worker refusal task" low)"
  TASK_SIGNAL_ID="$(create_task "Signal collision task" medium)"
  act_ready act3 \
    "task_review_id=$TASK_REVIEW_ID" \
    "task_autospawn_id=$TASK_AUTOSPAWN_ID" \
    "task_arbitration_id=$TASK_ARBITRATION_ID" \
    "task_refusal_id=$TASK_REFUSAL_ID" \
    "task_signal_id=$TASK_SIGNAL_ID"
  act_ack act3

  assign_and_start "$TASK_REVIEW_ID" "$WORKER_CODEX_ID"
  assign_and_start "$TASK_AUTOSPAWN_ID" "$WORKER_CLAUDE_ID"
  act_ready act4 "task_review_id=$TASK_REVIEW_ID" "task_autospawn_id=$TASK_AUTOSPAWN_ID"
  act_ack act4

  for code in \
    python_traceback_output \
    unauthorized_git_commit_during_run \
    python_used_in_bash_tool_use \
    absolute_manifest_path_used \
    jq_error_in_command_output \
    unverified_recursive_remove \
    hook_denied_tool_call \
    agent_repeated_error \
    agent_stalled_progress \
    cross_agent_file_conflict
  do
    "$SCRIPT_DIR/inject-heuristic-log.sh" --agent "$OBSERVER_ID" --code "$code" >/dev/null
  done
  run_harness_ignore_failure session observe "$SESSION_ID" --json --actor "$OBSERVER_ID" --project-dir "$PROJECT_DIR" >/dev/null
  act_ready act5 "observer_id=$OBSERVER_ID" "heuristic_code=python_traceback_output"
  act_ack act5

  IMPROVER_SOURCE="$ROOT/agents/plugins/harness/skills/harness/body.md"
  IMPROVER_CONTENTS="$STATE_ROOT/improver-body.md"
  cp "$IMPROVER_SOURCE" "$IMPROVER_CONTENTS"
  run_harness session improver apply "$SESSION_ID" \
    --project-dir "$PROJECT_DIR" \
    --actor "$IMPROVER_ID" \
    --issue-id "python_traceback_output/e2e" \
    --target plugin \
    --rel-path "harness/skills/harness/body.md" \
    --new-contents-file "$IMPROVER_CONTENTS" \
    --dry-run >/dev/null
  act_ready act6 "improver_id=$IMPROVER_ID"
  act_ack act6

  if [[ -n "$VIBE_WORKER_ID" ]]; then
    run_harness_ignore_failure session leave "$SESSION_ID" "$VIBE_WORKER_ID" --project-dir "$PROJECT_DIR" >/dev/null
    VIBE_WORKER_ID="$(join_agent worker vibe "Swarm Worker Vibe Rejoined" generalist)"
  fi
  run_harness session sync "$SESSION_ID" --json --project-dir "$PROJECT_DIR" >/dev/null
  TEMP_WORKER_ID="$(join_agent worker claude "Swarm Temporary Worker" generalist)"
  run_harness session leave "$SESSION_ID" "$TEMP_WORKER_ID" --project-dir "$PROJECT_DIR" >/dev/null
  act_ready act7 "vibe_worker_id=$VIBE_WORKER_ID"
  act_ack act7

  run_harness session task submit-for-review "$SESSION_ID" "$TASK_REVIEW_ID" \
    --project-dir "$PROJECT_DIR" \
    --actor "$WORKER_CODEX_ID" \
    --summary "ready"
  act_ready act8 "task_review_id=$TASK_REVIEW_ID" "worker_codex_id=$WORKER_CODEX_ID"
  act_ack act8

  run_harness session task claim-review "$SESSION_ID" "$TASK_REVIEW_ID" \
    --project-dir "$PROJECT_DIR" \
    --actor "$REVIEWER_CLAUDE_ID"
  if run_harness_may_fail session task claim-review "$SESSION_ID" "$TASK_REVIEW_ID" \
    --project-dir "$PROJECT_DIR" \
    --actor "$REVIEWER_DUP_CLAUDE_ID" >/dev/null 2>"$STATE_ROOT/duplicate-reviewer.err"
  then
    printf 'duplicate same-runtime review claim unexpectedly succeeded\n' >&2
    return 1
  fi
  run_harness session task claim-review "$SESSION_ID" "$TASK_REVIEW_ID" \
    --project-dir "$PROJECT_DIR" \
    --actor "$REVIEWER_CODEX_ID"
  run_harness session task submit-review "$SESSION_ID" "$TASK_REVIEW_ID" \
    --project-dir "$PROJECT_DIR" \
    --actor "$REVIEWER_CLAUDE_ID" \
    --verdict approve \
    --summary "LGTM"
  run_harness session task submit-review "$SESSION_ID" "$TASK_REVIEW_ID" \
    --project-dir "$PROJECT_DIR" \
    --actor "$REVIEWER_CODEX_ID" \
    --verdict approve \
    --summary "LGTM"
  act_ready act9 "task_review_id=$TASK_REVIEW_ID" "reviewer_runtime=claude"
  act_ack act9

  run_harness_ignore_failure session remove "$SESSION_ID" "$REVIEWER_CLAUDE_ID" --project-dir "$PROJECT_DIR" --actor "$LEADER_ID" >/dev/null
  run_harness_ignore_failure session remove "$SESSION_ID" "$REVIEWER_CODEX_ID" --project-dir "$PROJECT_DIR" --actor "$LEADER_ID" >/dev/null
  run_harness_ignore_failure session remove "$SESSION_ID" "$REVIEWER_DUP_CLAUDE_ID" --project-dir "$PROJECT_DIR" --actor "$LEADER_ID" >/dev/null
  run_harness session task submit-for-review "$SESSION_ID" "$TASK_AUTOSPAWN_ID" \
    --project-dir "$PROJECT_DIR" \
    --actor "$WORKER_CLAUDE_ID" \
    --summary "ready"
  run_harness session signal list "$SESSION_ID" --json --project-dir "$PROJECT_DIR" >/dev/null
  act_ready act10 "task_autospawn_id=$TASK_AUTOSPAWN_ID" "worker_claude_id=$WORKER_CLAUDE_ID"
  act_ack act10

  if run_harness_may_fail session task assign "$SESSION_ID" "$TASK_REFUSAL_ID" "$WORKER_CLAUDE_ID" \
    --project-dir "$PROJECT_DIR" \
    --actor "$LEADER_ID" >/dev/null 2>"$STATE_ROOT/busy-worker.err"
  then
    printf 'awaiting-review worker assignment unexpectedly succeeded\n' >&2
    return 1
  fi
  act_ready act11 "task_refusal_id=$TASK_REFUSAL_ID" "worker_claude_id=$WORKER_CLAUDE_ID"
  act_ack act11

  REVIEWER_ROUND_CLAUDE_ID="$(join_agent reviewer claude "Swarm Reviewer Claude Round" code-reviewer)"
  REVIEWER_ROUND_CODEX_ID="$(join_agent reviewer codex "Swarm Reviewer Codex Round" code-reviewer)"
  assign_and_start "$TASK_ARBITRATION_ID" "$WORKER_CODEX_ID"
  submit_request_changes_round "$TASK_ARBITRATION_ID" "$WORKER_CODEX_ID" "$REVIEWER_ROUND_CLAUDE_ID" "$REVIEWER_ROUND_CODEX_ID" "redoing"
  act_ready act12 "task_arbitration_id=$TASK_ARBITRATION_ID" "point_id=p1"
  act_ack act12

  run_harness session task update "$SESSION_ID" "$TASK_ARBITRATION_ID" \
    --project-dir "$PROJECT_DIR" \
    --status in_progress \
    --actor "$WORKER_CODEX_ID" >/dev/null || true
  submit_request_changes_round "$TASK_ARBITRATION_ID" "$WORKER_CODEX_ID" "$REVIEWER_ROUND_CLAUDE_ID" "$REVIEWER_ROUND_CODEX_ID" "round two"
  run_harness session task update "$SESSION_ID" "$TASK_ARBITRATION_ID" \
    --project-dir "$PROJECT_DIR" \
    --status in_progress \
    --actor "$WORKER_CODEX_ID" >/dev/null || true
  submit_request_changes_round "$TASK_ARBITRATION_ID" "$WORKER_CODEX_ID" "$REVIEWER_ROUND_CLAUDE_ID" "$REVIEWER_ROUND_CODEX_ID" "round three"
  run_harness session task arbitrate "$SESSION_ID" "$TASK_ARBITRATION_ID" \
    --project-dir "$PROJECT_DIR" \
    --actor "$LEADER_ID" \
    --verdict approve \
    --summary "shipping"
  act_ready act13 "task_arbitration_id=$TASK_ARBITRATION_ID"
  act_ack act13

  run_harness session signal send "$SESSION_ID" "$WORKER_CODEX_ID" \
    --project-dir "$PROJECT_DIR" \
    --command pause \
    --message "test" \
    --actor "$LEADER_ID" >/dev/null
  run_harness_ignore_failure session signal send "$SESSION_ID" "$WORKER_CODEX_ID" \
    --project-dir "$PROJECT_DIR" \
    --command pause \
    --message "test" \
    --actor "$LEADER_ID" >/dev/null
  act_ready act14 "agent_id=$WORKER_CODEX_ID"
  act_ack act14

  run_observe_commands
  act_ready act15 "session_id=$SESSION_ID"
  act_ack act15

  run_harness session end "$SESSION_ID" --project-dir "$PROJECT_DIR" --actor "$LEADER_ID" >/dev/null
  act_ready act16 "session_id=$SESSION_ID"
  act_ack act16

  printf 'act driver finished\n'
}

configure_xctestrun() {
  local source_path="$1"
  local destination_path="$2"

  python3 - "$source_path" "$destination_path" \
    "$STATE_ROOT" "$DATA_HOME" "$DAEMON_LOG" "$SESSION_ID" "$SYNC_DIR" <<'PY'
import plistlib
import shutil
import sys

source_path, destination_path, state_root, data_home, daemon_log, session_id, sync_dir = sys.argv[1:]

shutil.copyfile(source_path, destination_path)
with open(destination_path, "rb") as handle:
    payload = plistlib.load(handle)

target = payload["HarnessMonitorAgentsE2ETests"]
updates = {
    "HARNESS_MONITOR_ENABLE_SWARM_E2E": "1",
    "HARNESS_MONITOR_SWARM_E2E_STATE_ROOT": state_root,
    "HARNESS_MONITOR_SWARM_E2E_DATA_HOME": data_home,
    "HARNESS_MONITOR_SWARM_E2E_DAEMON_LOG": daemon_log,
    "HARNESS_MONITOR_SWARM_E2E_SESSION_ID": session_id,
    "HARNESS_MONITOR_SWARM_E2E_SYNC_DIR": sync_dir,
}

for key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
    environment = target.setdefault(key, {})
    environment.update(updates)

with open(destination_path, "wb") as handle:
    plistlib.dump(payload, handle, sort_keys=False)
PY
}

verify_final_state() {
  if [[ "$ASSERT_MODE" -ne 1 ]]; then
    return 0
  fi

  local final_json="$STATE_ROOT/final-status.json"
  run_harness session status "$SESSION_ID" --json --project-dir "$PROJECT_DIR" >"$final_json"
  jq -e '.status == "ended"' "$final_json" >/dev/null
  jq -e '[.tasks[] | select(.arbitration != null)] | length >= 1' "$final_json" >/dev/null
  jq -e '[.tasks[] | select(.source == "observe")] | length >= 1' "$final_json" >/dev/null
  local open_gaps
  open_gaps="$("$SCRIPT_DIR/gaps-open-count.sh")"
  [[ "$open_gaps" == "0" ]]
}

"$SCRIPT_DIR/seed-session-state.sh" --data-home "$DATA_HOME" >/dev/null

"$SCRIPT_DIR/probe-runtimes.sh" >"$STATE_ROOT/probe.json"
if [[ "$(jq '.required_missing | length' "$STATE_ROOT/probe.json")" != "0" ]]; then
  jq -r '"required runtimes missing: \(.required_missing | join(", "))"' "$STATE_ROOT/probe.json" >&2
  exit 1
fi

"$APP_ROOT/Scripts/generate.sh"
"$ROOT/scripts/cargo-local.sh" build --bin harness

TEST_ARGS=(
  -workspace "$APP_ROOT/HarnessMonitor.xcworkspace"
  -scheme "HarnessMonitorAgentsE2E"
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
)

HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE=1 "$XCODEBUILD_RUNNER" \
  "${TEST_ARGS[@]}" \
  CODE_SIGNING_ALLOWED=YES \
  build-for-testing

GENERATED_XCTESTRUN="$(
  find "$DERIVED_DATA_PATH/Build/Products" \
    -maxdepth 1 \
    -name 'HarnessMonitorAgentsE2E_*.xctestrun' \
    ! -name '*.configured.xctestrun' \
    -print \
    | sort \
    | tail -n1
)"
if [[ -z "$GENERATED_XCTESTRUN" ]]; then
  printf 'Failed to locate generated HarnessMonitorAgentsE2E .xctestrun file\n' >&2
  exit 1
fi
CONFIGURED_XCTESTRUN="${GENERATED_XCTESTRUN%.xctestrun}.swarm.configured.xctestrun"
configure_xctestrun "$GENERATED_XCTESTRUN" "$CONFIGURED_XCTESTRUN"

env XDG_DATA_HOME="$DATA_HOME" HARNESS_DAEMON_DATA_HOME="$DATA_HOME" \
  "$HARNESS_BINARY" daemon serve --sandboxed --host 127.0.0.1 --port 0 \
  >"$DAEMON_LOG" 2>&1 &
DAEMON_PID="$!"
wait_for_daemon

run_act_driver >"$ACT_DRIVER_LOG" 2>&1 &
ACT_DRIVER_PID="$!"

HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE=1 "$XCODEBUILD_RUNNER" \
  -xctestrun "$CONFIGURED_XCTESTRUN" \
  -destination "$DESTINATION" \
  CODE_SIGNING_ALLOWED=YES \
  test-without-building \
  "-only-testing:${ONLY_TESTING}"

wait "$ACT_DRIVER_PID"
ACT_DRIVER_PID=""
verify_final_state
