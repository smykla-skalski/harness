#!/bin/bash
set -euo pipefail

ROOT="${SRCROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
TARGET_KIND="${1:-all}"

case "$TARGET_KIND" in
  app)
    set -- "$ROOT/Sources/HarnessMonitor"
    ;;
  kit)
    set -- "$ROOT/Sources/HarnessMonitorKit"
    ;;
  tests)
    set -- "$ROOT/Tests/HarnessMonitorKitTests"
    ;;
  ui-tests)
    set -- "$ROOT/Tests/HarnessMonitorUITests"
    ;;
  all)
    set -- "$ROOT/Sources" "$ROOT/Tests/HarnessMonitorKitTests" "$ROOT/Tests/HarnessMonitorUITests"
    ;;
  *)
    echo "unknown lint target: $TARGET_KIND" >&2
    exit 1
    ;;
esac

SWIFT_FORMAT_BIN="${SWIFT_FORMAT_BIN:-$(command -v swift || true)}"
SWIFTLINT_BIN="${SWIFTLINT_BIN:-$(command -v swiftlint || true)}"

if [ -z "${SWIFTLINT_BIN}" ]; then
  for candidate in /opt/homebrew/bin/swiftlint /usr/local/bin/swiftlint; do
    if [ -x "$candidate" ]; then
      SWIFTLINT_BIN="$candidate"
      break
    fi
  done
fi

if [ -z "${SWIFT_FORMAT_BIN}" ]; then
  echo "swift-format is required on PATH" >&2
  exit 1
fi

if [ -z "${SWIFTLINT_BIN}" ]; then
  echo "swiftlint is required on PATH or at /opt/homebrew/bin/swiftlint" >&2
  exit 1
fi

for lint_path in "$@"; do
  "$SWIFT_FORMAT_BIN" format lint --recursive --parallel --strict "$lint_path"
  "$SWIFTLINT_BIN" lint --strict --no-cache --config "$ROOT/.swiftlint.yml" "$lint_path"
done
