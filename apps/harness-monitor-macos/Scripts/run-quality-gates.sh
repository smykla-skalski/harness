#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$ROOT/../.." && pwd)"
DESTINATION="${XCODEBUILD_DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${XCODEBUILD_DERIVED_DATA_PATH:-$REPO_ROOT/tmp/xcode-derived}"
FORMAT_CONFIG="$ROOT/.swift-format"
SWIFT_BIN="${SWIFT_BIN:-$(command -v swift || true)}"
SWIFTLINT_BIN="${SWIFTLINT_BIN:-$(command -v swiftlint || true)}"
SWIFTLINT_CACHE_PATH="${SWIFTLINT_CACHE_PATH:-$REPO_ROOT/tmp/swiftlint-cache/harness-monitor-macos}"

if [ -z "${SWIFT_BIN}" ]; then
  echo "swift is required on PATH" >&2
  exit 1
fi

if [ -z "${SWIFTLINT_BIN}" ]; then
  echo "swiftlint is required on PATH" >&2
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

mkdir -p "$SWIFTLINT_CACHE_PATH"

"$SWIFTLINT_BIN" lint \
  --config "$ROOT/.swiftlint.yml" \
  --working-directory "$ROOT" \
  --cache-path "$SWIFTLINT_CACHE_PATH" \
  --strict \
  --force-exclude \
  --quiet \
  "$ROOT/Sources" \
  "$ROOT/Tests/HarnessMonitorKitTests" \
  "$ROOT/Tests/HarnessMonitorUITests"

xcodebuild \
  -project "$ROOT/HarnessMonitor.xcodeproj" \
  -scheme "HarnessMonitor" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build-for-testing

SANDBOX_VIOLATIONS="$(log show \
  --predicate 'subsystem == "com.apple.sandbox.reporting" AND composedMessage CONTAINS "io.harnessmonitor"' \
  --last 10m \
  --style compact 2>/dev/null \
  | tail -n +2 \
  | sed '/^[[:space:]]*$/d' || true)"

if [ -n "$SANDBOX_VIOLATIONS" ]; then
  printf '\n=== Sandbox violations detected ===\n%s\n' "$SANDBOX_VIOLATIONS" >&2
  exit 1
fi
