#!/usr/bin/env bash
# Send initialize + tools/list to `harness mcp serve` over stdio and print
# the pretty-printed responses. Passes through to `harness` on $PATH; the
# socket can be overridden with HARNESS_MONITOR_MCP_SOCKET.
#
# Usage:
#   scripts/mcp-smoke.sh                 # initialize + tools/list
#   scripts/mcp-smoke.sh list_windows    # also tools/call list_windows
set -euo pipefail

hash -r 2>/dev/null || true
if [[ -n "${HARNESS_MCP_SMOKE_HARNESS_BIN:-}" ]]; then
  harness_bin="$HARNESS_MCP_SMOKE_HARNESS_BIN"
elif ! harness_bin=$(command -v harness 2>/dev/null); then
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

raw_output="$(mktemp "${TMPDIR:-/tmp}/mcp-smoke.XXXXXX")"
cleanup() {
  rm -f "$raw_output"
}
trap cleanup EXIT

printf '%s\n' "$requests" | "$harness_bin" mcp serve >"$raw_output"

while IFS= read -r line; do
  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$line" | jq .
  else
    printf '%s\n' "$line"
  fi
done <"$raw_output"

python3 - "$raw_output" <<'PY'
import json
import sys

failed = False
with open(sys.argv[1], encoding="utf-8") as handle:
    for line_number, line in enumerate(handle, start=1):
        if not line.strip():
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError as error:
            print(
                f"error: MCP smoke received invalid JSON on line {line_number}: {error}",
                file=sys.stderr,
            )
            failed = True
            continue
        if "error" in payload:
            print(
                f"error: MCP smoke received an error response for id {payload.get('id')}",
                file=sys.stderr,
            )
            failed = True
        result = payload.get("result")
        if isinstance(result, dict) and result.get("isError") is True:
            print(
                f"error: MCP smoke received an error response for id {payload.get('id')}",
                file=sys.stderr,
            )
            failed = True

sys.exit(1 if failed else 0)
PY
