#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
E2E_TOOL_PACKAGE="$ROOT/apps/harness-monitor/Tools/HarnessMonitorE2E"
APP_E2E_TOOL_BINARY="${HARNESS_MONITOR_E2E_TOOL_BINARY:-$E2E_TOOL_PACKAGE/.build/release/harness-monitor-e2e}"
# shellcheck source=apps/harness-monitor/Scripts/lib/swift-tool-env.sh
source "$ROOT/apps/harness-monitor/Scripts/lib/swift-tool-env.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/swift-package-freshness.sh
source "$ROOT/apps/harness-monitor/Scripts/lib/swift-package-freshness.sh"
sanitize_xcode_only_swift_environment

if [[ -z "${HARNESS_MONITOR_E2E_TOOL_BINARY:-}" ]]; then
  APP_E2E_TOOL_BINARY="$(
    ensure_swift_package_release_binary_fresh \
      "$E2E_TOOL_PACKAGE" \
      "harness-monitor-e2e"
  )"
fi

exec "$APP_E2E_TOOL_BINARY" seed-session-state "$@"
