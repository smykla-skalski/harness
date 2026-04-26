#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
CHECKOUT_ROOT="$(CDPATH='' cd -- "$ROOT/../.." && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$CHECKOUT_ROOT/scripts/lib/common-repo-root.sh"
COMMON_REPO_ROOT="$(resolve_common_repo_root "$CHECKOUT_ROOT")"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/xcodebuild-destination.sh
source "$ROOT/Scripts/lib/xcodebuild-destination.sh"
DESTINATION="$(harness_monitor_xcodebuild_destination)"
DERIVED_DATA_PATH="${XCODEBUILD_DERIVED_DATA_PATH:-$COMMON_REPO_ROOT/xcode-derived}"
CANONICAL_XCODEBUILD_RUNNER="$ROOT/Scripts/xcodebuild-with-lock.sh"
XCODEBUILD_RUNNER="${XCODEBUILD_RUNNER:-$CANONICAL_XCODEBUILD_RUNNER}"
GENERATE_PROJECT_SCRIPT="${GENERATE_PROJECT_SCRIPT:-$ROOT/Scripts/generate.sh}"

if [ "${XCODEBUILD_RUNNER}" != "${CANONICAL_XCODEBUILD_RUNNER}" ]; then
  echo "XCODEBUILD_RUNNER override is unsupported; use ${CANONICAL_XCODEBUILD_RUNNER}" >&2
  exit 1
fi

if [ ! -x "${XCODEBUILD_RUNNER}" ]; then
  echo "xcodebuild runner is not executable: ${XCODEBUILD_RUNNER}" >&2
  exit 1
fi

if [ ! -x "${GENERATE_PROJECT_SCRIPT}" ]; then
  echo "generate script is not executable: ${GENERATE_PROJECT_SCRIPT}" >&2
  exit 1
fi

"$GENERATE_PROJECT_SCRIPT"

"$XCODEBUILD_RUNNER" \
  -workspace "$ROOT/HarnessMonitor.xcworkspace" \
  -scheme "HarnessMonitor" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
