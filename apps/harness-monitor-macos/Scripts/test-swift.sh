#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DESTINATION="${XCODEBUILD_DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${XCODEBUILD_DERIVED_DATA_PATH:-$ROOT/DerivedData}"

clear_gatekeeper_metadata() {
  local build_products_path path

  build_products_path="$DERIVED_DATA_PATH/Build/Products/Debug"
  if [ ! -d "$build_products_path" ]; then
    return 0
  fi

  for path in \
    "$build_products_path"/*.app \
    "$build_products_path"/*.xctest \
    "$build_products_path"/*.framework
  do
    if [ -e "$path" ]; then
      xattr -dr com.apple.provenance "$path" 2>/dev/null || true
      xattr -dr com.apple.quarantine "$path" 2>/dev/null || true
    fi
  done
}

"$ROOT/Scripts/generate-project.sh"
"$ROOT/Scripts/lint-swift.sh" all
xcodebuild \
  -project "$ROOT/HarnessMonitor.xcodeproj" \
  -scheme HarnessMonitor \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build-for-testing

clear_gatekeeper_metadata

xcodebuild \
  -project "$ROOT/HarnessMonitor.xcodeproj" \
  -scheme HarnessMonitor \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  test-without-building
