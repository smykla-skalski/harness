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
FORMAT_CONFIG="$ROOT/.swift-format"
SWIFT_BIN="${SWIFT_BIN:-$(command -v swift || true)}"
SWIFTLINT_BIN="${SWIFTLINT_BIN:-$(command -v swiftlint || true)}"
SWIFTLINT_CACHE_PATH="${SWIFTLINT_CACHE_PATH:-$COMMON_REPO_ROOT/tmp/swiftlint-cache/harness-monitor-macos}"
LOG_BIN="${LOG_BIN:-log}"
APP_ENTITLEMENTS_PATH="${HARNESS_MONITOR_APP_ENTITLEMENTS_PATH:-$ROOT/HarnessMonitor.entitlements}"
DAEMON_ENTITLEMENTS_PATH="${HARNESS_MONITOR_DAEMON_ENTITLEMENTS_PATH:-$ROOT/HarnessMonitorDaemon.entitlements}"

if [ -z "${SWIFT_BIN}" ]; then
  echo "swift is required on PATH" >&2
  exit 1
fi

if [ -z "${SWIFTLINT_BIN}" ]; then
  echo "swiftlint is required on PATH" >&2
  exit 1
fi

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

require_entitlement() {
  local entitlements_path="$1"
  local subject="$2"
  local short_key="$3"
  local full_key="com.apple.security.files.$short_key"

  if ! /usr/bin/plutil -convert xml1 -o - "$entitlements_path" \
    | /usr/bin/grep -q "<key>$full_key</key>"; then
    echo "missing ${subject} entitlement: ${short_key}" >&2
    exit 1
  fi
}

require_exact_entitlement() {
  local entitlements_path="$1"
  local message="$2"
  local entitlement_key="$3"

  if ! /usr/bin/plutil -convert xml1 -o - "$entitlements_path" \
    | /usr/bin/grep -q "<key>$entitlement_key</key>"; then
    echo "$message" >&2
    exit 1
  fi
}

ensure_entitlement_absent() {
  local entitlements_path="$1"
  local message="$2"
  local entitlement_key="$3"

  if /usr/bin/plutil -convert xml1 -o - "$entitlements_path" \
    | /usr/bin/grep -q "<key>$entitlement_key</key>"; then
    echo "$message" >&2
    exit 1
  fi
}

"$GENERATE_PROJECT_SCRIPT"

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
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing

SANDBOX_VIOLATIONS="$("$LOG_BIN" show \
  --predicate 'subsystem == "com.apple.sandbox.reporting" AND composedMessage CONTAINS "io.harnessmonitor"' \
  --last 10m \
  --style compact 2>/dev/null \
  | tail -n +2 \
  | sed '/^[[:space:]]*$/d' || true)"

if [ -n "$SANDBOX_VIOLATIONS" ]; then
  printf '\n=== Sandbox violations detected ===\n%s\n' "$SANDBOX_VIOLATIONS" >&2
  exit 1
fi

# Verify sandbox entitlements declared for the app + daemon. The local quality
# gate builds unsigned to avoid macOS app-data permission prompts during
# routine validation, so assert the checked-in entitlements files rather than a
# live signature. The daemon helper binary still needs to exist in the built
# product unless the bundle step was explicitly disabled.
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/Harness Monitor.app"
DAEMON_PATH="$APP_PATH/Contents/Helpers/harness"

if [[ ! -d "$APP_PATH" ]]; then
  echo "built app missing at $APP_PATH" >&2
  exit 1
fi

for key in user-selected.read-write bookmarks.app-scope bookmarks.document-scope; do
  require_entitlement "$APP_ENTITLEMENTS_PATH" app "$key"
done

if [[ "${HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE:-0}" != "1" ]]; then
  if [[ ! -x "$DAEMON_PATH" ]]; then
    echo "daemon binary missing at $DAEMON_PATH" >&2
    exit 1
  fi
  ensure_entitlement_absent \
    "$DAEMON_ENTITLEMENTS_PATH" \
    "daemon still has temporary-exception entitlement" \
    "com.apple.security.temporary-exception.files.home-relative-path"
  require_exact_entitlement \
    "$DAEMON_ENTITLEMENTS_PATH" \
    "daemon missing user-selected.read-write" \
    "com.apple.security.files.user-selected.read-write"
  require_exact_entitlement \
    "$DAEMON_ENTITLEMENTS_PATH" \
    "daemon missing bookmarks.app-scope" \
    "com.apple.security.files.bookmarks.app-scope"
fi
