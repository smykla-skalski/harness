#!/bin/bash
set -euo pipefail

variant="${1:?variant arg required: monitor-app or ui-test-host}"

case "$variant" in
  monitor-app)
    source_entitlements="$PROJECT_DIR/HarnessMonitor.entitlements"
    ;;
  ui-test-host)
    source_entitlements="$PROJECT_DIR/HarnessMonitorUITestHost.entitlements"
    ;;
  *)
    printf 'unknown entitlement variant: %s\n' "$variant" >&2
    exit 64
    ;;
esac

output_entitlements="${SCRIPT_OUTPUT_FILE_0:-${DERIVED_FILE_DIR:?missing DERIVED_FILE_DIR}/${TARGET_NAME:?missing TARGET_NAME}.codesign.entitlements}"

if [ ! -f "$source_entitlements" ]; then
  printf 'missing entitlement source: %s\n' "$source_entitlements" >&2
  exit 66
fi

/bin/mkdir -p "$(dirname "$output_entitlements")"
/bin/cp "$source_entitlements" "$output_entitlements"
/usr/bin/plutil -lint "$output_entitlements" >/dev/null
