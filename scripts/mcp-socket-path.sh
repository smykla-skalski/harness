#!/usr/bin/env bash
# Print the resolved MCP accessibility socket path. Mirrors the CLI
# default_socket_path: respects HARNESS_MONITOR_MCP_SOCKET, otherwise
# falls back to the app-group container under $HOME.
set -euo pipefail

if [[ -n "${HARNESS_MONITOR_MCP_SOCKET:-}" ]]; then
  printf '%s\n' "$HARNESS_MONITOR_MCP_SOCKET"
  exit 0
fi

app_group="Q498EB36N4.io.harnessmonitor"
socket="$HOME/Library/Group Containers/$app_group/harness-monitor-mcp.sock"
printf '%s\n' "$socket"
