#!/bin/bash
set -euo pipefail

# Builds the harness daemon helper binary so it can be embedded by
# bundle-daemon-agent.sh. Wired as a scheme pre-action so cargo runs in
# parallel with the Xcode compile step.

if [ "${XCODE_RUNNING_FOR_PREVIEWS:-}" = "1" ] || [[ "${BUILD_DIR:-}" == *"/Previews/"* ]]; then
  exit 0
fi

if [ "${HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUILD:-}" = "1" ]; then
  exit 0
fi

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/daemon-bundle-env.sh
source "$SCRIPT_DIR/lib/daemon-bundle-env.sh"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/daemon-cargo-build.sh
source "$SCRIPT_DIR/lib/daemon-cargo-build.sh"

build_daemon_binary >/dev/null
