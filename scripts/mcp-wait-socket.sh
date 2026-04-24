#!/usr/bin/env bash
# Poll the accessibility registry socket until it is bound, or time out.
# Exits 0 when the socket is a live Unix socket, 1 on timeout, 2 on
# unexpected conditions.
#
# Usage:
#   scripts/mcp-wait-socket.sh [timeout_seconds]
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=scripts/lib/mcp-socket.sh
source "$ROOT/scripts/lib/mcp-socket.sh"

timeout_seconds=${1:-30}
socket_path=$("$ROOT/scripts/mcp-socket-path.sh")
deadline=$(( $(date +%s) + timeout_seconds ))
last_probe_error=""
last_non_socket_seen=0

while true; do
  if [[ -S "$socket_path" ]]; then
    if probe_output="$(mcp_probe_socket "$socket_path" 2>&1)"; then
      printf 'socket ready at %s\n' "$socket_path"
      exit 0
    fi
    last_probe_error="$probe_output"
  fi
  if [[ -e "$socket_path" ]]; then
    last_non_socket_seen=1
  fi
  if (( $(date +%s) >= deadline )); then
    if [[ -n "$last_probe_error" ]]; then
      printf 'error: socket at %s is not accepting connections: %s\n' \
        "$socket_path" "$last_probe_error" >&2
      exit 1
    fi
    if (( last_non_socket_seen )); then
      printf 'error: %s exists but is not a socket\n' "$socket_path" >&2
      exit 2
    fi
    printf 'error: timed out after %ss waiting for %s\n' \
      "$timeout_seconds" "$socket_path" >&2
    exit 1
  fi
  sleep 0.5
done
