#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
CHECKOUT_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=apps/harness-monitor/Scripts/lib/monitor-lanes.sh
source "$SCRIPT_DIR/lib/monitor-lanes.sh"

harness_monitor_apply_runtime_lane_environment "$CHECKOUT_ROOT"

export XCODEBUILDMCP_WORKSPACE_PATH="${XCODEBUILDMCP_WORKSPACE_PATH:-$SCRIPT_DIR/../HarnessMonitor.xcworkspace}"
export XCODEBUILDMCP_SCHEME="${XCODEBUILDMCP_SCHEME:-HarnessMonitor}"
export XCODEBUILDMCP_CONFIGURATION="${XCODEBUILDMCP_CONFIGURATION:-Debug}"
export XCODEBUILDMCP_SOCKET="${XCODEBUILDMCP_SOCKET:-$(harness_monitor_runtime_xcodebuildmcp_socket_path "$CHECKOUT_ROOT")}"

if (( $# > 0 )); then
  exec "$@"
fi

printf 'Harness Monitor runtime lane: %s\n' "$HARNESS_MONITOR_RUNTIME_LANE"
printf 'Daemon data home: %s\n' "$HARNESS_DAEMON_DATA_HOME"
printf 'Codex WS port: %s\n' "$HARNESS_CODEX_WS_PORT"
printf 'LaunchAgent label: %s\n' "$HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL"
printf 'XcodeBuildMCP socket: %s\n' "$XCODEBUILDMCP_SOCKET"
