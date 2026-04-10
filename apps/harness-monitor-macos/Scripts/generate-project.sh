#!/bin/bash
set -euo pipefail

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
XCODEGEN_BIN="${XCODEGEN_BIN:-$(command -v xcodegen || true)}"

if [ -z "${XCODEGEN_BIN}" ]; then
  for candidate in /opt/homebrew/bin/xcodegen /usr/local/bin/xcodegen; do
    if [ -x "$candidate" ]; then
      XCODEGEN_BIN="$candidate"
      break
    fi
  done
fi

if [ -z "${XCODEGEN_BIN}" ]; then
  echo "xcodegen is required on PATH or at /opt/homebrew/bin/xcodegen" >&2
  exit 1
fi

"$XCODEGEN_BIN" generate --spec "$ROOT/project.yml" --project "$ROOT"

PBXPROJ="$ROOT/HarnessMonitor.xcodeproj/project.pbxproj"
SCHEMES_DIR="$ROOT/HarnessMonitor.xcodeproj/xcshareddata/xcschemes"

# XcodeGen does not expose LastUpgradeCheck or product bundle file-reference names.
# Apply these as post-generation patches so they survive regeneration.

# Xcode 26 compatibility version (1430 = Xcode 14.3, 2640 = Xcode 26.0)
sed -i '' 's/LastUpgradeCheck = 1430/LastUpgradeCheck = 2640/g' "$PBXPROJ"

# Product bundle names: XcodeGen derives them from the target name, not PRODUCT_NAME.
# The shipped app and UI test host have display names with spaces; fix the file references.
sed -i '' \
  -e 's|/\* HarnessMonitor\.app \*/|/* Harness Monitor.app */|g' \
  -e 's|path = HarnessMonitor\.app;|path = "Harness Monitor.app";|g' \
  -e 's|/\* HarnessMonitorUITestHost\.app \*/|/* Harness Monitor UI Testing.app */|g' \
  -e 's|path = HarnessMonitorUITestHost\.app;|path = "Harness Monitor UI Testing.app";|g' \
  "$PBXPROJ"

# Scheme files carry the same LastUpgradeVersion attribute.
for scheme in "$SCHEMES_DIR"/*.xcscheme; do
  sed -i '' 's/LastUpgradeVersion = "1430"/LastUpgradeVersion = "2640"/g' "$scheme"
done
