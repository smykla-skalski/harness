#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$ROOT/../.." && pwd)"
DESTINATION="${XCODEBUILD_DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${XCODEBUILD_DERIVED_DATA_PATH:-$REPO_ROOT/xcode-derived}"
XCODEBUILD_RUNNER="${XCODEBUILD_RUNNER:-$ROOT/Scripts/xcodebuild-with-lock.sh}"
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

if [ ! -x "${XCODEBUILD_RUNNER}" ]; then
  echo "xcodebuild runner is not executable: ${XCODEBUILD_RUNNER}" >&2
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
  "$ROOT/Tests/HarnessMonitorUITestSupport" \
  "$ROOT/Tests/HarnessMonitorAgentsE2ETests" \
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
  "$ROOT/Tests/HarnessMonitorUITestSupport" \
  "$ROOT/Tests/HarnessMonitorAgentsE2ETests" \
  "$ROOT/Tests/HarnessMonitorUITests"

"$XCODEBUILD_RUNNER" \
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

# Verify sandbox entitlements on the built app + daemon. The daemon helper
# binary lives at <app>/Contents/Helpers/harness (bundled by
# Scripts/bundle-daemon-agent.sh); the LaunchAgents directory holds only the
# launchd plist. Skip the daemon assertion only when the agent bundle step
# was explicitly disabled via HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE=1.
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/Harness Monitor.app"
DAEMON_PATH="$APP_PATH/Contents/Helpers/harness"

if [[ -d "$APP_PATH" ]]; then
  entitlements="$(codesign --display --entitlements :- "$APP_PATH" 2>&1)"
  for key in user-selected.read-write bookmarks.app-scope bookmarks.document-scope; do
    echo "$entitlements" | grep -q "com.apple.security.files.$key" \
      || { echo "missing app entitlement: $key"; exit 1; }
  done

  if [[ "${HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE:-0}" != "1" ]]; then
    if [[ ! -x "$DAEMON_PATH" ]]; then
      echo "daemon binary missing at $DAEMON_PATH" >&2
      exit 1
    fi
    daemon_ent="$(codesign --display --entitlements :- "$DAEMON_PATH" 2>&1)"
    if echo "$daemon_ent" | grep -q "com.apple.security.temporary-exception.files.home-relative-path"; then
      echo "daemon still has temporary-exception entitlement"
      exit 1
    fi
    echo "$daemon_ent" | grep -q "com.apple.security.files.bookmarks.app-scope" \
      || { echo "daemon missing bookmarks.app-scope"; exit 1; }
  fi
fi
