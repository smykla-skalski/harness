#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
APP_E2E_TOOL_BINARY="${HARNESS_MONITOR_E2E_TOOL_BINARY:-$ROOT/apps/harness-monitor-macos/Tools/HarnessMonitorE2E/.build/release/harness-monitor-e2e}"

exec "$APP_E2E_TOOL_BINARY" inject-heuristic "$@"
