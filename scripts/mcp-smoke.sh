#!/usr/bin/env bash
# Send initialize + tools/list to `harness mcp serve` over stdio and print
# the pretty-printed responses. Passes through to `harness` on $PATH; the
# socket can be overridden with HARNESS_MONITOR_MCP_SOCKET.
#
# Usage:
#   scripts/mcp-smoke.sh                 # initialize + tools/list
#   scripts/mcp-smoke.sh list_windows    # also tools/call list_windows
set -euo pipefail

if ! command -v harness >/dev/null 2>&1; then
  printf "error: \`harness\` not on PATH. Run \`mise run install\` first.\n" >&2
  exit 2
fi

call_tool=${1:-}

requests=$(cat <<'JSON'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"mcp-smoke","version":"0"},"capabilities":{}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
JSON
)

if [[ -n "$call_tool" ]]; then
  requests+=$'\n'"{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"${call_tool}\",\"arguments\":{}}}"
fi

printf '%s\n' "$requests" | harness mcp serve | while IFS= read -r line; do
  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$line" | jq .
  else
    printf '%s\n' "$line"
  fi
done
