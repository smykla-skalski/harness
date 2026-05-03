#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"

XCODE_NATIVE_BRIDGE_PORT="${XCODE_NATIVE_BRIDGE_PORT:-48321}"
XCODE_NATIVE_BRIDGE_PLIST="${XCODE_NATIVE_BRIDGE_PLIST:-$HOME/Library/LaunchAgents/com.xcode-cli.bridge.plist}"
XCODE_NATIVE_HEALTH_TIMEOUT_SECONDS="${XCODE_NATIVE_HEALTH_TIMEOUT_SECONDS:-20}"
XCODE_NATIVE_XCODE_WAIT_SECONDS="${XCODE_NATIVE_XCODE_WAIT_SECONDS:-20}"
XCODE_NATIVE_OPEN_APP="${XCODE_NATIVE_OPEN_APP:-Xcode}"
XCODE_NATIVE_PROCESS_PATTERN="${XCODE_NATIVE_PROCESS_PATTERN:-/Applications/Xcode.app/Contents/MacOS/Xcode}"
XCODE_NATIVE_WORKSPACE_PATH="${XCODE_NATIVE_WORKSPACE_PATH:-$ROOT/HarnessMonitor.xcworkspace}"
MONITOR_USER_PROFILE_SCRIPT="${MONITOR_USER_PROFILE_SCRIPT:-$SCRIPT_DIR/user-runtime-profile.sh}"
MONITOR_GENERATE_SCRIPT="${MONITOR_GENERATE_SCRIPT:-$SCRIPT_DIR/generate.sh}"
XCODE_NATIVE_CTL_BIN="${XCODE_NATIVE_CTL_BIN:-$(command -v xcode-cli-ctl || true)}"
XCODE_NATIVE_CLI_BIN="${XCODE_NATIVE_CLI_BIN:-$(command -v xcode-cli || true)}"

require_tool() {
  local tool_path="$1"
  local tool_name="$2"
  if [[ -n "$tool_path" && -x "$tool_path" ]]; then
    return 0
  fi
  echo "error: required tool '$tool_name' is not installed or not executable" >&2
  case "$tool_name" in
    xcode-cli-ctl|xcode-cli)
      echo "  install the Node bridge first (brew/npm environment with xcode-cli available)" >&2
      ;;
  esac
  exit 127
}

bridge_status() {
  "$XCODE_NATIVE_CTL_BIN" status --port "$XCODE_NATIVE_BRIDGE_PORT"
}

bridge_is_healthy() {
  bridge_status 2>/dev/null | grep -Fq "Healthy: yes"
}

probe_bridge() {
  "$XCODE_NATIVE_CLI_BIN" windows --json >/dev/null
}

xcode_is_running() {
  pgrep -f "$XCODE_NATIVE_PROCESS_PATTERN" >/dev/null 2>&1
}

wait_for_xcode() {
  local deadline
  deadline=$((SECONDS + XCODE_NATIVE_XCODE_WAIT_SECONDS))
  while (( SECONDS < deadline )); do
    if xcode_is_running; then
      return 0
    fi
    sleep 1
  done
  echo "error: Xcode did not appear within ${XCODE_NATIVE_XCODE_WAIT_SECONDS}s" >&2
  return 1
}

ensure_workspace_generated() {
  if [[ -d "$XCODE_NATIVE_WORKSPACE_PATH" ]]; then
    return 0
  fi

  echo "info: generated workspace missing; refreshing it through the user lane..." >&2
  "$MONITOR_USER_PROFILE_SCRIPT" "$MONITOR_GENERATE_SCRIPT"
  if [[ ! -d "$XCODE_NATIVE_WORKSPACE_PATH" ]]; then
    echo "error: expected generated workspace at $XCODE_NATIVE_WORKSPACE_PATH" >&2
    return 1
  fi
}

ensure_xcode_running() {
  if xcode_is_running; then
    return 0
  fi

  echo "info: opening $XCODE_NATIVE_WORKSPACE_PATH in Xcode..." >&2
  open -a "$XCODE_NATIVE_OPEN_APP" "$XCODE_NATIVE_WORKSPACE_PATH"
  wait_for_xcode
}

wait_for_bridge_healthy() {
  local deadline
  deadline=$((SECONDS + XCODE_NATIVE_HEALTH_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if bridge_is_healthy && probe_bridge; then
      return 0
    fi
    sleep 1
  done
  return 1
}

start_or_restart_bridge() {
  if [[ -f "$XCODE_NATIVE_BRIDGE_PLIST" ]]; then
    "$XCODE_NATIVE_CTL_BIN" restart
  else
    "$XCODE_NATIVE_CTL_BIN" install --port "$XCODE_NATIVE_BRIDGE_PORT"
  fi
}

ensure_bridge() {
  require_tool "$XCODE_NATIVE_CTL_BIN" "xcode-cli-ctl"
  require_tool "$XCODE_NATIVE_CLI_BIN" "xcode-cli"

  ensure_workspace_generated
  ensure_xcode_running

  if bridge_is_healthy && probe_bridge; then
    bridge_status
    return 0
  fi

  start_or_restart_bridge
  if wait_for_bridge_healthy; then
    bridge_status
    return 0
  fi

  echo "error: xcode-native bridge failed to become healthy on port $XCODE_NATIVE_BRIDGE_PORT" >&2
  bridge_status >&2 || true
  echo "--- recent xcode-native bridge logs ---" >&2
  "$XCODE_NATIVE_CTL_BIN" logs -n 50 >&2 || true
  return 1
}

show_usage() {
  cat <<'EOF'
Usage: xcode-native-bridge.sh [ensure|status|restart|logs]

ensure   Generate the workspace if needed, open Xcode if needed, and make the xcode-native bridge healthy
status   Show bridge launchd + health status
restart  Reopen/rebind the bridge against the current Xcode session
logs     Show recent bridge logs (extra args are forwarded to xcode-cli-ctl logs)
EOF
}

main() {
  local command="${1:-ensure}"
  if (( $# > 0 )); then
    shift
  fi
  case "$command" in
    ensure)
      ensure_bridge "$@"
      ;;
    status)
      require_tool "$XCODE_NATIVE_CTL_BIN" "xcode-cli-ctl"
      bridge_status "$@"
      ;;
    restart)
      require_tool "$XCODE_NATIVE_CTL_BIN" "xcode-cli-ctl"
      require_tool "$XCODE_NATIVE_CLI_BIN" "xcode-cli"
      ensure_workspace_generated
      ensure_xcode_running
      start_or_restart_bridge
      wait_for_bridge_healthy
      bridge_status
      ;;
    logs)
      require_tool "$XCODE_NATIVE_CTL_BIN" "xcode-cli-ctl"
      "$XCODE_NATIVE_CTL_BIN" logs "$@"
      ;;
    -h|--help|help)
      show_usage
      ;;
    *)
      echo "error: unknown subcommand '$command'" >&2
      show_usage >&2
      return 2
      ;;
  esac
}

main "$@"
