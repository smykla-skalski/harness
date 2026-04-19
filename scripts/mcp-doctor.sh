#!/usr/bin/env bash
# Diagnose the local MCP setup end-to-end. One green/red line per
# prerequisite, an overall PASS/FAIL at the end, and a non-zero exit if
# any critical check fails so this can drive CI or pre-flight scripts.
set -uo pipefail

pass="\033[32mPASS\033[0m"
fail="\033[31mFAIL\033[0m"
warn="\033[33mWARN\033[0m"
info="\033[36m•\033[0m"

critical_failures=0
warnings=0

row() {
  printf '  %b  %s\n' "$1" "$2"
  shift 2
  for note in "$@"; do
    printf '        %s\n' "$note"
  done
}

fail_critical() {
  critical_failures=$((critical_failures + 1))
  row "$fail" "$@"
}

ok() { row "$pass" "$@"; }

warn() {
  warnings=$((warnings + 1))
  row "$warn" "$@"
}

note() { row "$info" "$@"; }

section() {
  printf '\n\033[1m%s\033[0m\n' "$1"
}

# 1. Rust CLI

section "Rust CLI"
if command -v harness >/dev/null 2>&1; then
  version=$(harness --version 2>/dev/null | head -1 || echo "unknown")
  path=$(command -v harness)
  ok "harness on PATH" "$version" "$path"
else
  fail_critical "harness not on PATH" "Run: mise run install"
fi

# 2. Input helper

section "Input helpers"
helper_release="mcp-servers/harness-monitor-registry/.build/release/harness-monitor-input"
helper_debug="mcp-servers/harness-monitor-registry/.build/debug/harness-monitor-input"
if [[ -n "${HARNESS_MONITOR_INPUT_BIN:-}" && -x "$HARNESS_MONITOR_INPUT_BIN" ]]; then
  ok "HARNESS_MONITOR_INPUT_BIN set and executable" "$HARNESS_MONITOR_INPUT_BIN"
elif [[ -x "$helper_release" ]]; then
  ok "harness-monitor-input built (release)" "$helper_release"
elif [[ -x "$helper_debug" ]]; then
  ok "harness-monitor-input built (debug)" "$helper_debug"
elif command -v cliclick >/dev/null 2>&1; then
  warn "Swift helper missing, falling back to cliclick" \
    "Run: mise run mcp:build:input-helper (preferred)"
else
  warn "No mouse backend available (no Swift helper, no cliclick)" \
    "Run: mise run mcp:build:input-helper" \
    "or:  brew install cliclick" \
    "Text input still works via osascript."
fi

# 3. Monitor.app build

section "Harness Monitor.app"
app_path="tmp/xcode-derived/Build/Products/Debug/Harness Monitor.app"
if [[ -d "$app_path" ]]; then
  ok "Debug build present" "$app_path"
else
  fail_critical "Debug build missing" \
    "Run: mise run mcp:build:monitor"
fi

if pgrep -f "Harness Monitor.app/Contents/MacOS/Harness Monitor" >/dev/null 2>&1; then
  ok "Harness Monitor.app is running"
else
  warn "Harness Monitor.app not running" \
    "Run: mise run mcp:launch:monitor"
fi

# 4. Socket + Preferences toggle

section "Registry socket"
socket_path=$(scripts/mcp-socket-path.sh)
if [[ -S "$socket_path" ]]; then
  ok "socket is bound" "$socket_path"
elif [[ -e "$socket_path" ]]; then
  fail_critical "path exists but is not a socket" "$socket_path"
else
  warn "socket not bound" \
    "Enable Preferences > MCP > \"Expose accessibility registry to MCP clients\"" \
    "Or run with HARNESS_MONITOR_MCP_FORCE_ENABLE=1 for dev builds" \
    "Expected path: $socket_path"
fi

# 5. Protocol round-trip

section "Protocol round-trip"
if command -v harness >/dev/null 2>&1; then
  probe_request='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"doctor","version":"0"},"capabilities":{}}}'
  probe_response=$(printf '%s\n' "$probe_request" | harness mcp serve 2>/dev/null | head -1 || true)
  if [[ -n "$probe_response" ]] \
    && printf '%s' "$probe_response" | grep -q '"protocolVersion":"2025-11-25"'; then
    ok "initialize round-trip succeeded (protocolVersion 2025-11-25)"
  else
    fail_critical "initialize round-trip failed" "got: ${probe_response:-<no response>}"
  fi
else
  note "skipped (harness not on PATH)"
fi

# 6. .mcp.json registration

section "Claude Code .mcp.json"
if [[ -f .mcp.json ]]; then
  if command -v jq >/dev/null 2>&1; then
    if jq -e '.mcpServers["harness-monitor"].command == "harness"' .mcp.json >/dev/null 2>&1; then
      ok "harness-monitor entry present in .mcp.json"
    else
      warn "harness-monitor not registered in .mcp.json" \
        "Run: mise run mcp:register-claude"
    fi
  else
    note "jq not installed; skipping .mcp.json check"
  fi
else
  warn ".mcp.json not found" \
    "Run: mise run mcp:register-claude"
fi

# Summary

printf '\n'
if (( critical_failures == 0 )); then
  if (( warnings == 0 )); then
    printf '\033[32mOK: every check passed.\033[0m\n'
  else
    printf '\033[32mOK: %d warning(s), no critical failures.\033[0m\n' "$warnings"
  fi
  exit 0
fi
printf '\033[31mFAIL: %d critical check(s) failed.\033[0m\n' "$critical_failures"
exit 1
