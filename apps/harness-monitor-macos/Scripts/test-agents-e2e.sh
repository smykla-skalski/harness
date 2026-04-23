#!/bin/bash
set -euo pipefail

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
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/rtk-shell.sh
source "$ROOT/Scripts/lib/rtk-shell.sh"
CODEX_BINARY="${HARNESS_MONITOR_E2E_CODEX_BINARY:-$(command -v codex || true)}"
ONLY_TESTING="${XCODE_ONLY_TESTING:-HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests}"
RUN_ID="${HARNESS_MONITOR_E2E_RUN_ID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
STATE_ROOT_PARENT="${HARNESS_MONITOR_E2E_STATE_ROOT_PARENT:-${TMPDIR:-/tmp}/HarnessMonitorAgentsE2E}"
STATE_ROOT="${HARNESS_MONITOR_E2E_STATE_ROOT:-$STATE_ROOT_PARENT/$RUN_ID}"
# This lane runs the sandboxed UI-testing host against a real external daemon.
# Keep its data home outside the shared app-group container so the runner does
# not touch another app's protected storage and trigger privacy prompts.
DATA_ROOT="${HARNESS_MONITOR_E2E_DATA_ROOT:-$STATE_ROOT/data-root}"
DATA_HOME="$DATA_ROOT/data-home"
LOG_ROOT="$STATE_ROOT/logs"
TERMINAL_SESSION_ID="sess-agents-e2e-terminal-${RUN_ID}"
CODEX_SESSION_ID="sess-agents-e2e-codex-${RUN_ID}"
DAEMON_LOG="$LOG_ROOT/daemon.log"
BRIDGE_LOG="$LOG_ROOT/bridge.log"
E2E_PROJECT_DIR="${HARNESS_MONITOR_E2E_PROJECT_DIR:-$CHECKOUT_ROOT}"
CODEX_WORKSPACE=""
APPROVAL_FILE=""

if [[ "$XCODEBUILD_RUNNER" != "$CANONICAL_XCODEBUILD_RUNNER" ]]; then
  echo "XCODEBUILD_RUNNER override is unsupported; use $CANONICAL_XCODEBUILD_RUNNER" >&2
  exit 1
fi

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

HARNESS_BINARY="${HARNESS_MONITOR_E2E_HARNESS_BINARY:-$(resolve_harness_binary_path)}"
KEEP_STATE_ROOT="${HARNESS_MONITOR_E2E_KEEP_STATE_ROOT:-0}"
CODEX_PORT_OVERRIDE="${HARNESS_MONITOR_E2E_CODEX_PORT:-}"

DAEMON_PID=""
BRIDGE_PID=""

if [[ -z "$CODEX_BINARY" ]]; then
  echo "codex binary not found in PATH; set HARNESS_MONITOR_E2E_CODEX_BINARY to run Agents e2e" >&2
  exit 1
fi

mkdir -p "$DATA_HOME" "$LOG_ROOT"

cleanup() {
  local status="$1"

  stop_bridge_process
  if [[ -n "$DAEMON_PID" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi

  if [[ "$status" -eq 0 ]] && [[ "$KEEP_STATE_ROOT" != "1" ]]; then
    rm -rf "$STATE_ROOT"
    if [[ "$DATA_ROOT" != "$STATE_ROOT" ]] && [[ "$DATA_ROOT" != "$STATE_ROOT"/* ]]; then
      rm -rf "$DATA_ROOT"
    fi
    return
  fi

  {
    echo "Agents e2e state preserved at: $STATE_ROOT"
    echo "Agents e2e data root preserved at: $DATA_ROOT"
    if [[ -f "$DAEMON_LOG" ]]; then
      echo "--- daemon log tail ---"
      print_log_tail_compact 80 "$DAEMON_LOG"
    fi
    if [[ -f "$BRIDGE_LOG" ]]; then
      echo "--- bridge log tail ---"
      print_log_tail_compact 80 "$BRIDGE_LOG"
    fi
  } >&2
}

trap 'status=$?; cleanup "$status"; exit "$status"' EXIT

stop_bridge_process() {
  if [[ -n "$BRIDGE_PID" ]] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
    kill "$BRIDGE_PID" 2>/dev/null || true
  fi
  if [[ -n "$BRIDGE_PID" ]]; then
    wait "$BRIDGE_PID" 2>/dev/null || true
  fi
  BRIDGE_PID=""
}

allocate_unused_local_port() {
  python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

bridge_failed_with_port_conflict() {
  [[ -f "$BRIDGE_LOG" ]] && grep -Fq "Address already in use" "$BRIDGE_LOG"
}

seed_observability_config() {
  local config_path="$DATA_HOME/harness/observability/config.json"
  mkdir -p "$(dirname "$config_path")"
  cat >"$config_path" <<'EOF'
{
  "enabled": true,
  "grpc_endpoint": "http://127.0.0.1:4317",
  "http_endpoint": "http://127.0.0.1:4318",
  "grafana_url": "http://127.0.0.1:3000",
  "tempo_url": "http://127.0.0.1:3200",
  "loki_url": "http://127.0.0.1:3100",
  "prometheus_url": "http://127.0.0.1:9090",
  "pyroscope_url": "http://127.0.0.1:4040",
  "monitor_smoke_enabled": false,
  "headers": {}
}
EOF
}

run_harness() {
  XDG_DATA_HOME="$DATA_HOME" HARNESS_DAEMON_DATA_HOME="$DATA_HOME" "$HARNESS_BINARY" "$@"
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

bridge_is_ready() {
  local status_json
  if ! status_json="$(run_harness bridge status 2>/dev/null)"; then
    return 1
  fi
  BRIDGE_STATUS_JSON="$status_json" python3 - <<'PY'
import json
import os
import sys

try:
    payload = json.loads(os.environ["BRIDGE_STATUS_JSON"])
except Exception:
    sys.exit(1)

if payload.get("running") is not True:
    sys.exit(1)

capabilities = payload.get("capabilities") or {}
for name in ("codex", "agent-tui"):
    capability = capabilities.get(name) or {}
    if capability.get("healthy") is not True:
        sys.exit(1)
PY
}

wait_for_bridge() {
  local deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    if bridge_is_ready; then
      return 0
    fi
    if [[ -n "$BRIDGE_PID" ]] && ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
      wait "$BRIDGE_PID" 2>/dev/null || true
      return 2
    fi
    sleep 0.25
  done
  echo "Timed out waiting for bridge readiness" >&2
  return 1
}

start_bridge() {
  local max_attempts=1
  if [[ -z "$CODEX_PORT_OVERRIDE" ]]; then
    max_attempts=5
  fi

  for (( attempt=1; attempt<=max_attempts; attempt++ )); do
    local codex_port="$CODEX_PORT_OVERRIDE"
    if [[ -z "$codex_port" ]]; then
      codex_port="$(allocate_unused_local_port)"
    fi

    {
      echo "=== bridge attempt $attempt codex_port=$codex_port ==="
    } >>"$BRIDGE_LOG"

    run_harness bridge start \
      --capability codex \
      --capability agent-tui \
      --codex-port "$codex_port" \
      --codex-path "$CODEX_BINARY" \
      >>"$BRIDGE_LOG" 2>&1 &
    BRIDGE_PID="$!"

    if wait_for_bridge; then
      return 0
    fi

    local wait_status=$?
    stop_bridge_process

    if (( wait_status == 2 )) && [[ -z "$CODEX_PORT_OVERRIDE" ]] && bridge_failed_with_port_conflict; then
      continue
    fi

    if (( wait_status == 2 )); then
      echo "Bridge exited before readiness" >&2
    fi
    return 1
  done

  echo "Bridge failed to start after $max_attempts attempts" >&2
  return 1
}

create_session() {
  local session_id="$1"
  local title="$2"
  local context="$3"

  run_harness session start \
    --context "$context" \
    --title "$title" \
    --project-dir "$E2E_PROJECT_DIR" \
    --session-id "$session_id" \
    >/dev/null
}

resolve_session_workspace() {
  local session_id="$1"
  local workspace
  workspace="$(
    run_harness session status "$session_id" --json --project-dir "$E2E_PROJECT_DIR" \
      | jq -r '.worktree_path'
  )"
  if [[ -z "$workspace" ]]; then
    echo "Failed to resolve workspace for session $session_id" >&2
    return 1
  fi
  printf '%s\n' "$workspace"
}

verify_nonempty_file() {
  local path="$1"
  if [[ ! -s "$path" ]]; then
    echo "Expected non-empty file at $path" >&2
    return 1
  fi
}

verify_post_run_state() {
  verify_nonempty_file "$DATA_HOME/harness/daemon/harness.db"
  if [[ -e "$DATA_HOME/harness/harness-cache.store" ]]; then
    verify_nonempty_file "$DATA_HOME/harness/harness-cache.store"
  fi

  if [[ "$ONLY_TESTING" == *"testCodexThreadSteersAndApprovesThroughSandboxedBridge"* ]] \
    || [[ "$ONLY_TESTING" == "HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests" ]]
  then
    verify_nonempty_file "$APPROVAL_FILE"
    if [[ "$(tr -d '\r' <"$APPROVAL_FILE" | tr -d '\n')" != "UI_APPROVAL_OK" ]]; then
      echo "Unexpected approval file contents in $APPROVAL_FILE" >&2
      return 1
    fi
  fi
}

configure_xctestrun() {
  local source_path="$1"
  local destination_path="$2"

  python3 - "$source_path" "$destination_path" \
    "$STATE_ROOT" "$DATA_HOME" "$DAEMON_LOG" "$BRIDGE_LOG" \
    "$TERMINAL_SESSION_ID" "$CODEX_SESSION_ID" <<'PY'
import plistlib
import shutil
import sys

(
    source_path,
    destination_path,
    state_root,
    data_home,
    daemon_log,
    bridge_log,
    terminal_session_id,
    codex_session_id,
) = sys.argv[1:]

shutil.copyfile(source_path, destination_path)
with open(destination_path, "rb") as handle:
    payload = plistlib.load(handle)

target = payload["HarnessMonitorAgentsE2ETests"]
updates = {
    "HARNESS_MONITOR_E2E_STATE_ROOT": state_root,
    "HARNESS_MONITOR_E2E_DATA_HOME": data_home,
    "HARNESS_MONITOR_E2E_DAEMON_LOG": daemon_log,
    "HARNESS_MONITOR_E2E_BRIDGE_LOG": bridge_log,
    "HARNESS_MONITOR_E2E_TERMINAL_SESSION_ID": terminal_session_id,
    "HARNESS_MONITOR_E2E_CODEX_SESSION_ID": codex_session_id,
    "HARNESS_MONITOR_ENABLE_AGENTS_E2E": "1",
}

for key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
    environment = target.setdefault(key, {})
    environment.update(updates)

with open(destination_path, "wb") as handle:
    plistlib.dump(payload, handle, sort_keys=False)
PY
}

seed_observability_config

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
CONFIGURED_XCTESTRUN="${GENERATED_XCTESTRUN%.xctestrun}.configured.xctestrun"
configure_xctestrun "$GENERATED_XCTESTRUN" "$CONFIGURED_XCTESTRUN"

run_harness daemon serve --sandboxed --host 127.0.0.1 --port 0 >"$DAEMON_LOG" 2>&1 &
DAEMON_PID="$!"
wait_for_daemon

: >"$BRIDGE_LOG"
start_bridge

create_session \
  "$TERMINAL_SESSION_ID" \
  "Agents E2E Terminal" \
  "Run the explicit monitor Agents end-to-end smoke for terminal-backed agents."

create_session \
  "$CODEX_SESSION_ID" \
  "Agents E2E Codex" \
  "Run the explicit monitor Agents end-to-end smoke for Codex threads."
CODEX_WORKSPACE="$(resolve_session_workspace "$CODEX_SESSION_ID")"
APPROVAL_FILE="$CODEX_WORKSPACE/approved.txt"

if HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE=1 "$XCODEBUILD_RUNNER" \
  -xctestrun "$CONFIGURED_XCTESTRUN" \
  -destination "$DESTINATION" \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building \
  "-only-testing:${ONLY_TESTING}"
then
  verify_post_run_state
fi
