#!/usr/bin/env bash
# Launch the Debug build of Harness Monitor.app with the dev-mode env
# override so the accessibility registry host starts automatically. The
# override only works in DEBUG builds (gated inside
# HarnessMonitorMCPPreferencesDefaults.forceEnableFromEnvironment).
#
# If an instance is already running we do nothing - the env var would
# not reach it anyway.
set -euo pipefail

app_path="tmp/xcode-derived/Build/Products/Debug/Harness Monitor.app"
if [[ ! -d "$app_path" ]]; then
  printf 'error: %s not found. Run `mise run mcp:build:monitor` first.\n' "$app_path" >&2
  exit 1
fi

if pgrep -f "Harness Monitor.app/Contents/MacOS/Harness Monitor" >/dev/null 2>&1; then
  printf 'Harness Monitor.app is already running; env override has no effect on a running process.\n'
  printf 'Quit it first if you want to apply HARNESS_MONITOR_MCP_FORCE_ENABLE=1.\n'
  exit 0
fi

printf 'launching with HARNESS_MONITOR_MCP_FORCE_ENABLE=1...\n'
open -n -a "$app_path" --env "HARNESS_MONITOR_MCP_FORCE_ENABLE=1"
