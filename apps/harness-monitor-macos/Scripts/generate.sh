#!/bin/bash
set -euo pipefail

# Canonical Harness Monitor project generator. Runs Tuist to materialize the
# Xcode project, then post-generate.sh to write buildServer.json and sync
# version metadata. Invoked by mise (monitor:macos:generate) and by the
# scripts that need a generated project as a precondition.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"

TUIST_BIN="${TUIST_BIN:-$(command -v tuist || true)}"
if [ -z "$TUIST_BIN" ]; then
  echo "tuist is required on PATH (pinned via mise)" >&2
  exit 1
fi

if [ ! -d "$ROOT/Tuist/.build" ]; then
  "$TUIST_BIN" install --path "$ROOT"
fi

"$TUIST_BIN" generate --no-open --path "$ROOT"
"$SCRIPT_DIR/post-generate.sh"
