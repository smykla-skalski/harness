#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
APP_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
CHECKOUT_ROOT="$(CDPATH='' cd -- "$APP_ROOT/../.." && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$CHECKOUT_ROOT/scripts/lib/common-repo-root.sh"
COMMON_REPO_ROOT="$(resolve_common_repo_root "$CHECKOUT_ROOT")"
BUILD_ROOT="${XCODE_BUILD_SERVER_BUILD_ROOT:-$COMMON_REPO_ROOT/xcode-derived}"
SCHEME="${XCODE_BUILD_SERVER_SCHEME:-HarnessMonitor}"
SERVER_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/harness-xcode-build-server.XXXXXX")"

cleanup() {
  rm -rf "$SERVER_TMP_DIR"
}

trap cleanup EXIT

if [ -n "${XCODE_BUILD_SERVER_BIN:-}" ]; then
  if [ ! -x "$XCODE_BUILD_SERVER_BIN" ]; then
    echo "XCODE_BUILD_SERVER_BIN must point to an executable xcode-build-server binary" >&2
    exit 1
  fi
else
  XCODE_BUILD_SERVER_BIN="$(command -v xcode-build-server || true)"
fi

if [ -z "$XCODE_BUILD_SERVER_BIN" ]; then
  echo "xcode-build-server is required on PATH or via XCODE_BUILD_SERVER_BIN" >&2
  exit 1
fi

(
  cd "$SERVER_TMP_DIR"
  "$XCODE_BUILD_SERVER_BIN" config \
    -workspace "$APP_ROOT/HarnessMonitor.xcworkspace" \
    -scheme "$SCHEME" \
    --build_root "$BUILD_ROOT" \
    --skip-validate-bin >/dev/null
  "$XCODE_BUILD_SERVER_BIN" serve "$@"
)
