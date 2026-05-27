#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
APP_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
PERF_CLI_PACKAGE_DIR="$APP_ROOT/Tools/HarnessMonitorPerf"
# shellcheck source=apps/harness-monitor/Scripts/lib/swift-tool-env.sh
source "$SCRIPT_DIR/lib/swift-tool-env.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/swift-package-freshness.sh
source "$SCRIPT_DIR/lib/swift-package-freshness.sh"
sanitize_xcode_only_swift_environment

PERF_CLI_BINARY="$(
  ensure_swift_package_release_binary_fresh \
    "$PERF_CLI_PACKAGE_DIR" \
    "harness-monitor-perf"
)"

exec "$PERF_CLI_BINARY" "$@"
