#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$ROOT/../.." && pwd)"
DESTINATION="${XCODEBUILD_DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${XCODEBUILD_DERIVED_DATA_PATH:-$REPO_ROOT/tmp/xcode-derived}"
FORMAT_CONFIG="$ROOT/.swift-format"
SWIFT_BIN="${SWIFT_BIN:-$(command -v swift || true)}"

if [ -z "${SWIFT_BIN}" ]; then
  echo "swift is required on PATH" >&2
  exit 1
fi

"$ROOT/Scripts/generate-project.sh"

"$SWIFT_BIN" format lint \
  --configuration "$FORMAT_CONFIG" \
  --recursive \
  --parallel \
  --strict \
  "$ROOT/Sources" \
  "$ROOT/Tests/HarnessMonitorKitTests" \
  "$ROOT/Tests/HarnessMonitorUITests"

xcodebuild \
  -project "$ROOT/HarnessMonitor.xcodeproj" \
  -scheme "HarnessMonitor" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build-for-testing
