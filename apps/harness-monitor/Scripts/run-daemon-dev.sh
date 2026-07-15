#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
CHECKOUT_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=apps/harness-monitor/Scripts/lib/monitor-lanes.sh
source "$SCRIPT_DIR/lib/monitor-lanes.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/local-harness-binary.sh
source "$SCRIPT_DIR/lib/local-harness-binary.sh"

harness_monitor_apply_runtime_lane_environment "$CHECKOUT_ROOT"

prepare_daemon_runtime_root() {
  local runtime_root
  runtime_root="$HARNESS_DAEMON_DATA_HOME/harness"

  mkdir -p "$runtime_root/daemon"
  if [[ -x /usr/bin/xattr ]]; then
    /usr/bin/xattr -dr com.apple.provenance "$runtime_root" 2>/dev/null || true
    /usr/bin/xattr -dr com.apple.quarantine "$runtime_root" 2>/dev/null || true
  fi
}

daemon_manifest_path() {
  printf '%s/harness/daemon/manifest.json\n' "$HARNESS_DAEMON_DATA_HOME"
}

log_dir="${HARNESS_MONITOR_DAEMON_DEV_LOG_DIR:-$CHECKOUT_ROOT/tmp/logs}"
mkdir -p "$log_dir"
log="$log_dir/$(date +%y%m%d%H%M)-monitor-daemon-dev.log"
prepare_daemon_runtime_root
binary="$(resolve_local_harness_binary \
  "$CHECKOUT_ROOT" \
  HARNESS_MONITOR_DAEMON_DEV_BIN \
  harness-daemon)"
manifest_path="$(daemon_manifest_path)"

exec python3 "$SCRIPT_DIR/run-harness-command.py" \
  --log "$log" \
  --accepted-interrupt-statuses "0,129,130,143" \
  --cleanup-path "$manifest_path" \
  --cleanup-description "daemon interrupt cleanup" \
  --child-new-session \
  -- "$binary" dev
