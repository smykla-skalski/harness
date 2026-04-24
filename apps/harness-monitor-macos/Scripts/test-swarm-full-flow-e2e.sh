#!/bin/bash
set -euo pipefail

# Swarm full-flow e2e orchestrator. Boots an isolated harness daemon, seeds a
# session with leader/worker/reviewer agents plus a task that is already parked
# in AwaitingReview, then hands off to xcodebuild to run the companion
# `SwarmFullFlowTests` XCUITest against that state.

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
CHECKOUT_ROOT="$(CDPATH='' cd -- "$ROOT/../.." && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$CHECKOUT_ROOT/scripts/lib/common-repo-root.sh"
COMMON_REPO_ROOT="$(resolve_common_repo_root "$CHECKOUT_ROOT")"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/xcodebuild-destination.sh
source "$ROOT/Scripts/lib/xcodebuild-destination.sh"
DESTINATION="$(harness_monitor_xcodebuild_destination)"
DERIVED_DATA_PATH="${XCODEBUILD_DERIVED_DATA_PATH:-$COMMON_REPO_ROOT/xcode-derived}"
CANONICAL_XCODEBUILD_RUNNER="$ROOT/Scripts/xcodebuild-with-lock.sh"
XCODEBUILD_RUNNER="${XCODEBUILD_RUNNER:-$CANONICAL_XCODEBUILD_RUNNER}"

if [[ "$XCODEBUILD_RUNNER" != "$CANONICAL_XCODEBUILD_RUNNER" ]]; then
  echo "XCODEBUILD_RUNNER override is unsupported; use $CANONICAL_XCODEBUILD_RUNNER" >&2
  exit 1
fi

ONLY_TESTING="${XCODE_ONLY_TESTING:-HarnessMonitorAgentsE2ETests/SwarmFullFlowTests/testSwarmFullFlowRendersReviewUI}"
RUN_ID="${HARNESS_MONITOR_SWARM_E2E_RUN_ID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
STATE_ROOT_PARENT="${HARNESS_MONITOR_SWARM_E2E_STATE_ROOT_PARENT:-${TMPDIR:-/tmp}/HarnessMonitorSwarmE2E}"
STATE_ROOT="${HARNESS_MONITOR_SWARM_E2E_STATE_ROOT:-$STATE_ROOT_PARENT/$RUN_ID}"
DATA_ROOT="${HARNESS_MONITOR_SWARM_E2E_DATA_ROOT:-$STATE_ROOT/data-root}"
DATA_HOME="$DATA_ROOT/data-home"
LOG_ROOT="$STATE_ROOT/logs"
DAEMON_LOG="$LOG_ROOT/daemon.log"
SESSION_ID="sess-swarm-full-flow-${RUN_ID}"
# Agent IDs and task ID are issued by the daemon and captured from CLI JSON
# output during seeding. They flow into the configured xctestrun env.
LEADER_ID=""
WORKER_ID=""
REVIEWER_ID=""
TASK_ID=""
E2E_PROJECT_DIR="${HARNESS_MONITOR_SWARM_E2E_PROJECT_DIR:-$CHECKOUT_ROOT}"
KEEP_STATE_ROOT="${HARNESS_MONITOR_SWARM_E2E_KEEP_STATE_ROOT:-0}"

resolve_harness_binary_path() {
  local cargo_target_dir
  cargo_target_dir="$(
    "$CHECKOUT_ROOT/scripts/cargo-local.sh" --print-env \
      | awk -F= '/^CARGO_TARGET_DIR=/{print $2}'
  )"
  if [[ -z "$cargo_target_dir" ]]; then
    echo "failed to resolve CARGO_TARGET_DIR via scripts/cargo-local.sh --print-env" >&2
    exit 1
  fi
  printf '%s/debug/harness\n' "$cargo_target_dir"
}

HARNESS_BINARY="${HARNESS_MONITOR_SWARM_E2E_HARNESS_BINARY:-$(resolve_harness_binary_path)}"
DAEMON_PID=""

mkdir -p "$DATA_HOME" "$LOG_ROOT"

cleanup() {
  local status="$1"

  if [[ -n "$DAEMON_PID" ]]; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  DAEMON_PID=""

  if [[ "$status" -eq 0 ]] && [[ "$KEEP_STATE_ROOT" != "1" ]]; then
    rm -rf "$STATE_ROOT"
    if [[ "$DATA_ROOT" != "$STATE_ROOT"* ]]; then
      rm -rf "$DATA_ROOT"
    fi
    return
  fi

  {
    echo "Swarm e2e state preserved at: $STATE_ROOT"
    if [[ -f "$DAEMON_LOG" ]]; then
      echo "--- daemon log tail ---"
      tail -n 80 "$DAEMON_LOG"
    fi
  } >&2
}

trap 'status=$?; cleanup "$status"; exit "$status"' EXIT

run_harness() {
  XDG_DATA_HOME="$DATA_HOME" HARNESS_DAEMON_DATA_HOME="$DATA_HOME" \
    "$HARNESS_BINARY" "$@"
}

wait_for_daemon() {
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    if run_harness daemon status >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  echo "Timed out waiting for daemon readiness" >&2
  return 1
}

capture_agent_id() {
  local role="$1"
  local runtime="$2"
  local name="$3"
  run_harness session join "$SESSION_ID" \
    --project-dir "$E2E_PROJECT_DIR" \
    --role "$role" \
    --runtime "$runtime" \
    --name "$name" \
    | jq -r --arg name "$name" \
        '.agents[] | select(.name == $name) | .agentId' \
    | head -n1
}

seed_session_and_review_state() {
  run_harness session start \
    --project-dir "$E2E_PROJECT_DIR" \
    --session-id "$SESSION_ID" \
    --title "Swarm Full Flow E2E" \
    --context "Drive full review cycle for swarm full-flow XCUITest." >/dev/null

  LEADER_ID="$(capture_agent_id leader claude 'Swarm Leader')"
  WORKER_ID="$(capture_agent_id worker codex 'Swarm Worker')"
  REVIEWER_ID="$(capture_agent_id reviewer claude 'Swarm Reviewer')"

  if [[ -z "$LEADER_ID" || -z "$WORKER_ID" || -z "$REVIEWER_ID" ]]; then
    echo "Failed to capture seeded agent IDs (leader=$LEADER_ID worker=$WORKER_ID reviewer=$REVIEWER_ID)" >&2
    return 1
  fi

  TASK_ID="$(
    run_harness session task create "$SESSION_ID" \
      --project-dir "$E2E_PROJECT_DIR" \
      --title "Review full-flow task" \
      --severity high \
      --actor "$LEADER_ID" \
      | jq -r '.taskId'
  )"
  if [[ -z "$TASK_ID" || "$TASK_ID" == "null" ]]; then
    echo "Failed to capture seeded task id" >&2
    return 1
  fi

  run_harness session task assign "$SESSION_ID" "$TASK_ID" "$WORKER_ID" \
    --project-dir "$E2E_PROJECT_DIR" \
    --actor "$LEADER_ID" >/dev/null

  run_harness session task update "$SESSION_ID" "$TASK_ID" \
    --project-dir "$E2E_PROJECT_DIR" \
    --status in-progress \
    --actor "$WORKER_ID" >/dev/null

  run_harness session task submit-for-review "$SESSION_ID" "$TASK_ID" \
    --project-dir "$E2E_PROJECT_DIR" \
    --actor "$WORKER_ID" \
    --summary "Ready for review" >/dev/null
}

configure_xctestrun() {
  local source_path="$1"
  local destination_path="$2"

  python3 - "$source_path" "$destination_path" \
    "$STATE_ROOT" "$DATA_HOME" "$DAEMON_LOG" \
    "$SESSION_ID" "$TASK_ID" "$REVIEWER_ID" <<'PY'
import plistlib
import shutil
import sys

(
    source_path,
    destination_path,
    state_root,
    data_home,
    daemon_log,
    session_id,
    task_id,
    reviewer_id,
) = sys.argv[1:]

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
    "HARNESS_MONITOR_SWARM_E2E_TASK_ID": task_id,
    "HARNESS_MONITOR_SWARM_E2E_REVIEWER_AGENT_ID": reviewer_id,
}

for key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
    environment = target.setdefault(key, {})
    environment.update(updates)

with open(destination_path, "wb") as handle:
    plistlib.dump(payload, handle, sort_keys=False)
PY
}

"$ROOT/Scripts/generate-project.sh"
"$CHECKOUT_ROOT/scripts/cargo-local.sh" build --bin harness

TEST_ARGS=(
  -project "$ROOT/HarnessMonitor.xcodeproj"
  -scheme "HarnessMonitorAgentsE2E"
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
)

HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE=1 "$XCODEBUILD_RUNNER" \
  "${TEST_ARGS[@]}" \
  CODE_SIGNING_ALLOWED=NO \
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
  echo "Failed to locate generated HarnessMonitorAgentsE2E .xctestrun file" >&2
  exit 1
fi
CONFIGURED_XCTESTRUN="${GENERATED_XCTESTRUN%.xctestrun}.swarm.configured.xctestrun"
configure_xctestrun "$GENERATED_XCTESTRUN" "$CONFIGURED_XCTESTRUN"

env XDG_DATA_HOME="$DATA_HOME" HARNESS_DAEMON_DATA_HOME="$DATA_HOME" \
  "$HARNESS_BINARY" daemon serve --sandboxed --host 127.0.0.1 --port 0 \
  >"$DAEMON_LOG" 2>&1 &
DAEMON_PID="$!"
wait_for_daemon

seed_session_and_review_state

HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE=1 "$XCODEBUILD_RUNNER" \
  -xctestrun "$CONFIGURED_XCTESTRUN" \
  -destination "$DESTINATION" \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building \
  "-only-testing:${ONLY_TESTING}"
