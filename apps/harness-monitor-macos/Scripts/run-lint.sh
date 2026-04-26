#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
CHECKOUT_ROOT="$(CDPATH='' cd -- "$ROOT/../.." && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$CHECKOUT_ROOT/scripts/lib/common-repo-root.sh"
COMMON_REPO_ROOT="$(resolve_common_repo_root "$CHECKOUT_ROOT")"

GENERATE_PROJECT_SCRIPT="${GENERATE_PROJECT_SCRIPT:-$ROOT/Scripts/generate.sh}"
FORMAT_CONFIG="$ROOT/.swift-format"
SWIFT_BIN="${SWIFT_BIN:-$(command -v swift || true)}"
SWIFTLINT_BIN="${SWIFTLINT_BIN:-$(command -v swiftlint || true)}"
SWIFTLINT_CACHE_PATH="${SWIFTLINT_CACHE_PATH:-$COMMON_REPO_ROOT/tmp/swiftlint-cache/harness-monitor-macos}"

FORMAT_TARGETS=(
  "$ROOT/Sources"
  "$ROOT/Tests/HarnessMonitorKitTests"
  "$ROOT/Tests/HarnessMonitorUITestSupport"
  "$ROOT/Tests/HarnessMonitorAgentsE2ETests"
  "$ROOT/Tests/HarnessMonitorUITests"
  "$ROOT/Tools/HarnessMonitorE2E/Sources"
  "$ROOT/Tools/HarnessMonitorE2E/Tests"
)

MAIN_LINT_TARGETS=(
  "$ROOT/Sources"
  "$ROOT/Tests/HarnessMonitorKitTests"
  "$ROOT/Tests/HarnessMonitorUITestSupport"
  "$ROOT/Tests/HarnessMonitorAgentsE2ETests"
  "$ROOT/Tests/HarnessMonitorUITests"
)

E2E_LINT_TARGETS=(
  "$ROOT/Tools/HarnessMonitorE2E/Sources"
  "$ROOT/Tools/HarnessMonitorE2E/Tests"
)

if [ -z "${SWIFT_BIN}" ]; then
  echo "swift is required on PATH" >&2
  exit 1
fi

if [ -z "${SWIFTLINT_BIN}" ]; then
  echo "swiftlint is required on PATH" >&2
  exit 1
fi

if [ ! -x "${GENERATE_PROJECT_SCRIPT}" ]; then
  echo "generate script is not executable: ${GENERATE_PROJECT_SCRIPT}" >&2
  exit 1
fi

"$GENERATE_PROJECT_SCRIPT"

"$SWIFT_BIN" format lint \
  --configuration "$FORMAT_CONFIG" \
  --recursive \
  --parallel \
  --strict \
  "${FORMAT_TARGETS[@]}"

mkdir -p "$SWIFTLINT_CACHE_PATH"

"$SWIFTLINT_BIN" lint \
  --config "$ROOT/.swiftlint.yml" \
  --working-directory "$ROOT" \
  --cache-path "$SWIFTLINT_CACHE_PATH" \
  --strict \
  --force-exclude \
  --quiet \
  "${MAIN_LINT_TARGETS[@]}"

"$SWIFTLINT_BIN" lint \
  --config "$ROOT/Tools/HarnessMonitorE2E/.swiftlint.yml" \
  --working-directory "$ROOT/Tools/HarnessMonitorE2E" \
  --cache-path "$SWIFTLINT_CACHE_PATH" \
  --strict \
  --force-exclude \
  --quiet \
  "${E2E_LINT_TARGETS[@]}"
