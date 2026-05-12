#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
CHECKOUT_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/monitor-lanes.sh
source "$SCRIPT_DIR/lib/monitor-lanes.sh"

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

resolve_local_cargo_target_dir() {
  local target_dir

  if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
    printf '%s\n' "$CARGO_TARGET_DIR"
    return 0
  fi

  target_dir="$(
    "$CHECKOUT_ROOT/scripts/cargo-local.sh" --print-env \
      | command awk -F= '/^CARGO_TARGET_DIR=/{print $2}'
  )"
  if [[ -z "$target_dir" ]]; then
    printf 'failed to resolve CARGO_TARGET_DIR via scripts/cargo-local.sh --print-env\n' >&2
    exit 1
  fi

  printf '%s\n' "$target_dir"
}

resolve_local_harness_binary() {
  local target_dir binary_path

  binary_path="${HARNESS_MONITOR_DAEMON_DEV_BIN:-}"
  if [[ -n "$binary_path" ]]; then
    if [[ ! -x "$binary_path" ]]; then
      printf 'configured daemon dev binary is not executable: %s\n' "$binary_path" >&2
      exit 1
    fi
    printf '%s\n' "$binary_path"
    return 0
  fi

  target_dir="$(resolve_local_cargo_target_dir)"
  "$CHECKOUT_ROOT/scripts/cargo-local.sh" build --quiet --bin harness >/dev/null
  binary_path="$target_dir/debug/harness"
  if [[ ! -x "$binary_path" ]]; then
    printf 'failed to resolve built local harness binary at %s\n' "$binary_path" >&2
    exit 1
  fi

  printf '%s\n' "$binary_path"
}

daemon_manifest_path() {
  printf '%s/harness/daemon/manifest.json\n' "$HARNESS_DAEMON_DATA_HOME"
}

log_dir="${HARNESS_MONITOR_DAEMON_DEV_LOG_DIR:-$CHECKOUT_ROOT/tmp/logs}"
mkdir -p "$log_dir"
log="$log_dir/$(date +%y%m%d%H%M)-monitor-daemon-dev.log"
prepare_daemon_runtime_root
binary="$(resolve_local_harness_binary)"
manifest_path="$(daemon_manifest_path)"

exec python3 "$SCRIPT_DIR/run-daemon-dev.py" "$binary" "$log" "$manifest_path"
