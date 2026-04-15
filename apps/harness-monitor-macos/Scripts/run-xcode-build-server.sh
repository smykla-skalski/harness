#!/bin/bash
set -euo pipefail

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

exec "$XCODE_BUILD_SERVER_BIN" "$@"
