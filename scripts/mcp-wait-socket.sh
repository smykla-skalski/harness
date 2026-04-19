#!/usr/bin/env bash
# Poll the accessibility registry socket until it is bound, or time out.
# Exits 0 when the socket is a live Unix socket, 1 on timeout, 2 on
# unexpected conditions.
#
# Usage:
#   scripts/mcp-wait-socket.sh [timeout_seconds]
set -euo pipefail

timeout_seconds=${1:-30}
socket_path=$(scripts/mcp-socket-path.sh)
deadline=$(( $(date +%s) + timeout_seconds ))

while true; do
  if [[ -S "$socket_path" ]]; then
    printf 'socket ready at %s\n' "$socket_path"
    exit 0
  fi
  if [[ -e "$socket_path" ]]; then
    printf 'error: %s exists but is not a socket\n' "$socket_path" >&2
    exit 2
  fi
  if (( $(date +%s) >= deadline )); then
    printf 'error: timed out after %ss waiting for %s\n' \
      "$timeout_seconds" "$socket_path" >&2
    exit 1
  fi
  sleep 0.5
done
