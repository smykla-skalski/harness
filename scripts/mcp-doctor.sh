#!/usr/bin/env bash
# Diagnose the local MCP setup end-to-end. One green/red line per
# prerequisite, an overall PASS/FAIL at the end, and a non-zero exit if
# any critical check fails so this can drive CI or pre-flight scripts.
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$ROOT/scripts/lib/common-repo-root.sh"
# shellcheck source=scripts/lib/mcp-socket.sh
source "$ROOT/scripts/lib/mcp-socket.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/swift-tool-env.sh
source "$ROOT/apps/harness-monitor/Scripts/lib/swift-tool-env.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/swift-package-freshness.sh
source "$ROOT/apps/harness-monitor/Scripts/lib/swift-package-freshness.sh"
COMMON_REPO_ROOT="$(resolve_common_repo_root "$ROOT")"
hash -r 2>/dev/null || true
sanitize_xcode_only_swift_environment

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

# 1. Rust MCP server

section "Rust MCP server"
if mcp_bin=$(command -v harness-mcp 2>/dev/null); then
  version=$("$mcp_bin" --version 2>/dev/null | head -1 || echo "unknown")
  path="$mcp_bin"
  ok "harness-mcp on PATH" "$version" "$path"
else
  fail_critical "harness-mcp not on PATH" "Run: mise run install"
fi

# 2. Input helper

section "Input helpers"
helper_package="mcp-servers/harness-monitor-registry"
helper_release="mcp-servers/harness-monitor-registry/.build/release/harness-monitor-input"
helper_debug="mcp-servers/harness-monitor-registry/.build/debug/harness-monitor-input"
if [[ -n "${HARNESS_MONITOR_INPUT_BIN:-}" && -x "$HARNESS_MONITOR_INPUT_BIN" ]]; then
  ok "HARNESS_MONITOR_INPUT_BIN set and executable" "$HARNESS_MONITOR_INPUT_BIN"
elif [[ -x "$helper_release" ]]; then
  if swift_package_has_newer_sources_than_binary "$helper_package" "$helper_release"; then
    warn "harness-monitor-input release binary is stale" \
      "$helper_release" \
      "Run: mise run mcp:build:input-helper"
  else
    ok "harness-monitor-input built (release, fresh)" "$helper_release"
  fi
elif [[ -x "$helper_debug" ]]; then
  if swift_package_has_newer_sources_than_binary "$helper_package" "$helper_debug"; then
    warn "harness-monitor-input debug binary is stale" \
      "$helper_debug" \
      "Run: mise run mcp:build:input-helper"
  else
    ok "harness-monitor-input built (debug, fresh)" "$helper_debug"
  fi
elif command -v cliclick >/dev/null 2>&1; then
  warn "Swift helper missing, falling back to cliclick" \
    "Run: mise run mcp:build:input-helper (preferred)"
else
  warn "No input backend available (no Swift helper, no cliclick)" \
    "Run: mise run mcp:build:input-helper" \
    "or:  brew install cliclick"
fi

# 3. Monitor.app build

section "Harness Monitor.app"
app_path="$COMMON_REPO_ROOT/xcode-derived/Build/Products/Debug/Harness Monitor.app"
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

# 4. Socket + Settings toggle

section "Registry socket"
socket_path=$("$ROOT/scripts/mcp-socket-path.sh")
if [[ -S "$socket_path" ]]; then
  if probe_output="$(mcp_probe_socket "$socket_path" 2>&1)"; then
    ok "socket is accepting registry ping" "$socket_path"
  else
    fail_critical "socket is not accepting connections" \
      "$socket_path" \
      "$probe_output" \
      "Launch with: mise run mcp:launch:dev"
  fi
elif [[ -e "$socket_path" ]]; then
  fail_critical "path exists but is not a socket" "$socket_path"
else
  warn "socket not bound" \
    "Enable Settings > MCP > \"Expose accessibility registry to MCP clients\"" \
    "Or run with HARNESS_MONITOR_MCP_FORCE_ENABLE=1 for dev builds" \
    "Expected path: $socket_path"
fi

# 5. Protocol round-trip

section "Protocol round-trip"
if [[ -n "${mcp_bin:-}" ]]; then
  probe_request='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"doctor","version":"0"},"capabilities":{}}}'
  probe_response=$(printf '%s\n' "$probe_request" | "$mcp_bin" serve 2>/dev/null | head -1 || true)
  if [[ -n "$probe_response" ]] \
    && printf '%s' "$probe_response" | grep -q '"protocolVersion":"2025-11-25"'; then
    ok "initialize round-trip succeeded (protocolVersion 2025-11-25)"
  else
    fail_critical "initialize round-trip failed" "got: ${probe_response:-<no response>}"
  fi
else
  note "skipped (harness-mcp not on PATH)"
fi

# 6. .mcp.json registration

section "Claude Code .mcp.json"
if [[ -f .mcp.json ]]; then
  if command -v jq >/dev/null 2>&1; then
    if jq -e '.mcpServers["harness-monitor"].command == "harness-mcp" and .mcpServers["harness-monitor"].args == ["serve"]' .mcp.json >/dev/null 2>&1; then
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
