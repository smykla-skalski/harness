#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$ROOT/../.." && pwd)"
DESTINATION="${XCODEBUILD_DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${XCODEBUILD_DERIVED_DATA_PATH:-$REPO_ROOT/tmp/xcode-derived}"
XCODEBUILD_RUNNER="${XCODEBUILD_RUNNER:-$ROOT/Scripts/xcodebuild-with-lock.sh}"

"$ROOT/Scripts/generate-project.sh"
"$REPO_ROOT/scripts/cargo-local.sh" build --bin harness

"$XCODEBUILD_RUNNER" \
  -project "$ROOT/HarnessMonitor.xcodeproj" \
  -scheme "HarnessMonitorAgentsE2E" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build-for-testing

"$XCODEBUILD_RUNNER" \
  -project "$ROOT/HarnessMonitor.xcodeproj" \
  -scheme "HarnessMonitorAgentsE2E" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  test-without-building \
  -only-testing:HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests
