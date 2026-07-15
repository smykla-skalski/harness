#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
CHECKOUT_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=apps/harness-monitor/Scripts/lib/monitor-lanes.sh
source "$SCRIPT_DIR/lib/monitor-lanes.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/local-harness-binary.sh
source "$SCRIPT_DIR/lib/local-harness-binary.sh"

harness_monitor_apply_runtime_lane_environment "$CHECKOUT_ROOT"

log_dir="${HARNESS_MONITOR_BRIDGE_START_LOG_DIR:-$CHECKOUT_ROOT/tmp/logs}"
mkdir -p "$log_dir"
log="$log_dir/$(date +%y%m%d%H%M)-monitor-bridge-start.log"
binary="$(resolve_local_harness_binary \
  "$CHECKOUT_ROOT" \
  HARNESS_MONITOR_BRIDGE_START_BIN \
  harness-bridge)"

exec python3 "$SCRIPT_DIR/run-harness-command.py" \
  --log "$log" \
  --accepted-interrupt-statuses "0,129,130,143" \
  --child-new-session \
  -- "$binary" start
