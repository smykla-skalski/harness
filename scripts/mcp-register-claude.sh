#!/usr/bin/env bash
# Idempotently patch .mcp.json at the repo root to register (or
# unregister) the harness-monitor MCP server.
#
#   scripts/mcp-register-claude.sh            # add or update entry
#   scripts/mcp-register-claude.sh remove     # remove entry if present
#   scripts/mcp-register-claude.sh show       # print current state
#
# Requires jq. Writes atomically via a sibling tmp file.
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  printf "error: jq not found on PATH. Install with \`brew install jq\`.\n" >&2
  exit 2
fi

target_file=.mcp.json
mode=${1:-add}

ensure_file() {
  if [[ ! -f "$target_file" ]]; then
    printf '{"mcpServers":{}}\n' >"$target_file"
  fi
}

atomic_write() {
  local tmp
  tmp=$(mktemp "${target_file}.XXXXXX")
  cat >"$tmp"
  mv "$tmp" "$target_file"
}

add_entry() {
  ensure_file
  jq '.mcpServers //= {} | .mcpServers["harness-monitor"] = {"command":"harness","args":["mcp","serve"]}' \
    "$target_file" | atomic_write
  printf 'registered harness-monitor in %s\n' "$target_file"
}

remove_entry() {
  if [[ ! -f "$target_file" ]]; then
    printf '%s does not exist; nothing to remove.\n' "$target_file"
    return 0
  fi
  if jq -e '.mcpServers["harness-monitor"]' "$target_file" >/dev/null 2>&1; then
    jq 'del(.mcpServers["harness-monitor"])' "$target_file" | atomic_write
    printf 'removed harness-monitor from %s\n' "$target_file"
  else
    printf 'harness-monitor not present in %s\n' "$target_file"
  fi
}

show_entry() {
  if [[ ! -f "$target_file" ]]; then
    printf '%s does not exist.\n' "$target_file"
    return 0
  fi
  jq '.mcpServers["harness-monitor"] // "not registered"' "$target_file"
}

case "$mode" in
  add|register) add_entry ;;
  remove|unregister) remove_entry ;;
  show|status) show_entry ;;
  *)
    printf 'usage: %s [add|remove|show]\n' "$0" >&2
    exit 2
    ;;
esac
