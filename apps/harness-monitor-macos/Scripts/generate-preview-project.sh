#!/bin/bash
set -euo pipefail

ROOT="${SRCROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
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

"$XCODEGEN_BIN" generate --spec "$ROOT/preview-project.yml" --project "$ROOT"
