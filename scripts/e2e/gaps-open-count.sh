#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
LEDGER="$ROOT/docs/e2e/swarm-gaps.md"

if [[ ! -f "$LEDGER" ]]; then
  printf '0\n'
  exit 0
fi

awk -F'|' '
  BEGIN { count = 0 }
  /^\|[[:space:]]*[^|]+[[:space:]]*\|[[:space:]]*[Oo]pen[[:space:]]*\|/ { count++ }
  END { print count }
' "$LEDGER"
