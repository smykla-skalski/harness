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
CODEX_MODEL_OVERRIDE="${HARNESS_MONITOR_E2E_CODEX_MODEL:-}"
CODEX_EFFORT_OVERRIDE="${HARNESS_MONITOR_E2E_CODEX_EFFORT:-}"
E2E_TOOL_PACKAGE="$ROOT/Tools/HarnessMonitorE2E"
E2E_TOOL_BINARY="${HARNESS_MONITOR_E2E_TOOL_BINARY:-$E2E_TOOL_PACKAGE/.build/release/harness-monitor-e2e}"
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
MANIFEST_PATH="$STATE_ROOT/prepare-manifest.json"
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

if [[ -z "$CODEX_BINARY" ]]; then
  echo "codex binary not found in PATH; set HARNESS_MONITOR_E2E_CODEX_BINARY to run Agents e2e" >&2
  exit 1
fi

mkdir -p "$DATA_HOME" "$LOG_ROOT"

ensure_e2e_tool_binary() {
  if [[ -x "$E2E_TOOL_BINARY" ]]; then
    return 0
  fi
  echo "Building harness-monitor-e2e helper at $E2E_TOOL_BINARY" >&2
  swift build -c release --package-path "$E2E_TOOL_PACKAGE" >&2
  if [[ ! -x "$E2E_TOOL_BINARY" ]]; then
    echo "harness-monitor-e2e binary missing after build at $E2E_TOOL_BINARY" >&2
    exit 1
  fi
}

cleanup() {
  local status="$1"
  local keep_flag=()
  if [[ "$status" -ne 0 ]] || [[ "$KEEP_STATE_ROOT" == "1" ]]; then
    keep_flag=(--keep-state)
  fi

  if [[ -f "$MANIFEST_PATH" ]]; then
    "$E2E_TOOL_BINARY" teardown --manifest "$MANIFEST_PATH" "${keep_flag[@]}" || true
  fi

  if [[ "$status" -eq 0 ]] && [[ "$KEEP_STATE_ROOT" != "1" ]]; then
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

resolve_supported_codex_launch() {
  if [[ -n "$CODEX_MODEL_OVERRIDE" ]]; then
    return 0
  fi

  local resolved
  if ! resolved="$("$E2E_TOOL_BINARY" resolve-codex-launch --codex-binary "$CODEX_BINARY" 2>/dev/null)"; then
    return 0
  fi

  if [[ -z "$resolved" ]]; then
    return 0
  fi

  CODEX_MODEL_OVERRIDE="$(printf '%s\n' "$resolved" | sed -n '1p')"
  CODEX_EFFORT_OVERRIDE="$(printf '%s\n' "$resolved" | sed -n '2p')"
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

  "$E2E_TOOL_BINARY" configure-xctestrun \
    --source "$source_path" \
    --destination "$destination_path" \
    --set "HARNESS_MONITOR_ENABLE_AGENTS_E2E=1" \
    --set "HARNESS_MONITOR_E2E_STATE_ROOT=$STATE_ROOT" \
    --set "HARNESS_MONITOR_E2E_DATA_HOME=$DATA_HOME" \
    --set "HARNESS_MONITOR_E2E_DAEMON_LOG=$DAEMON_LOG" \
    --set "HARNESS_MONITOR_E2E_BRIDGE_LOG=$BRIDGE_LOG" \
    --set "HARNESS_MONITOR_E2E_TERMINAL_SESSION_ID=$TERMINAL_SESSION_ID" \
    --set "HARNESS_MONITOR_E2E_CODEX_SESSION_ID=$CODEX_SESSION_ID" \
    --set "HARNESS_MONITOR_E2E_CODEX_MODEL=$CODEX_MODEL_OVERRIDE" \
    --set "HARNESS_MONITOR_E2E_CODEX_EFFORT=$CODEX_EFFORT_OVERRIDE"
}

ensure_e2e_tool_binary
resolve_supported_codex_launch

"$ROOT/Scripts/generate.sh"
"$CHECKOUT_ROOT/scripts/cargo-local.sh" build --bin harness

TEST_ARGS=(
  -workspace "$ROOT/HarnessMonitor.xcworkspace"
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
  echo "Failed to locate generated HarnessMonitorAgentsE2E .xctestrun file" >&2
  exit 1
fi
CONFIGURED_XCTESTRUN="${GENERATED_XCTESTRUN%.xctestrun}.configured.xctestrun"
configure_xctestrun "$GENERATED_XCTESTRUN" "$CONFIGURED_XCTESTRUN"

prepare_args=(
  prepare
  --state-root "$STATE_ROOT"
  --data-root "$DATA_ROOT"
  --data-home "$DATA_HOME"
  --daemon-log "$DAEMON_LOG"
  --bridge-log "$BRIDGE_LOG"
  --harness-binary "$HARNESS_BINARY"
  --codex-binary "$CODEX_BINARY"
  --project-dir "$E2E_PROJECT_DIR"
  --terminal-session-id "$TERMINAL_SESSION_ID"
  --codex-session-id "$CODEX_SESSION_ID"
  --manifest-output "$MANIFEST_PATH"
)
if [[ -n "$CODEX_PORT_OVERRIDE" ]]; then
  prepare_args+=(--codex-port "$CODEX_PORT_OVERRIDE")
fi
"$E2E_TOOL_BINARY" "${prepare_args[@]}"

CODEX_WORKSPACE="$(/usr/bin/awk -F'"' '/"codexWorkspace"/{print $4; exit}' "$MANIFEST_PATH")"
if [[ -z "$CODEX_WORKSPACE" ]]; then
  echo "Failed to read codexWorkspace from $MANIFEST_PATH" >&2
  exit 1
fi
APPROVAL_FILE="$CODEX_WORKSPACE/approved.txt"

if HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE=1 "$XCODEBUILD_RUNNER" \
  -xctestrun "$CONFIGURED_XCTESTRUN" \
  -destination "$DESTINATION" \
  CODE_SIGNING_ALLOWED=YES \
  test-without-building \
  "-only-testing:${ONLY_TESTING}"
then
  verify_post_run_state
else
  exit $?
fi
