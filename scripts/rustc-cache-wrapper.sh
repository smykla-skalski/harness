#!/usr/bin/env bash
set -euo pipefail
unalias -a 2>/dev/null || true

if command -v sccache >/dev/null 2>&1; then
  exec sccache "$@"
fi

exec "$@"
