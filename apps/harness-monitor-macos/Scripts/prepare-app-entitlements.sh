#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
APP_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"

project_temp_dir="${PROJECT_TEMP_DIR:?missing PROJECT_TEMP_DIR}"
output_dir="$project_temp_dir/GeneratedAppEntitlements"

copy_entitlements() {
  local target_name="$1"
  local source_name="$2"
  local source_entitlements="$APP_ROOT/$source_name"
  local output_entitlements="$output_dir/$target_name.codesign.entitlements"

  if [ ! -f "$source_entitlements" ]; then
    printf 'missing entitlement source: %s\n' "$source_entitlements" >&2
    exit 66
  fi

  /bin/cp "$source_entitlements" "$output_entitlements"
  /usr/bin/plutil -lint "$output_entitlements" >/dev/null
}

/bin/mkdir -p "$output_dir"
copy_entitlements "HarnessMonitor" "HarnessMonitor.entitlements"
copy_entitlements "HarnessMonitorUITestHost" "HarnessMonitorUITestHost.entitlements"
