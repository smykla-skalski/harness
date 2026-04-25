#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
LEDGER="$ROOT/docs/e2e/swarm-gaps.md"
ID=""
STATUS="Open"
SEVERITY="medium"
SUBSYSTEM="e2e"
CURRENT="runtime deviation captured by swarm e2e"
DESIRED="deviation is triaged and either fixed or documented"
CLOSED_BY=""

while (($#)); do
  case "$1" in
    --id) ID="$2"; shift 2 ;;
    --status) STATUS="$2"; shift 2 ;;
    --severity) SEVERITY="$2"; shift 2 ;;
    --subsystem) SUBSYSTEM="$2"; shift 2 ;;
    --current) CURRENT="$2"; shift 2 ;;
    --desired) DESIRED="$2"; shift 2 ;;
    --closed-by) CLOSED_BY="$2"; shift 2 ;;
    --note) CURRENT="$2"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

if [[ -z "$ID" ]]; then
  printf 'append-gap requires --id\n' >&2
  exit 64
fi

mkdir -p "$(dirname -- "$LEDGER")"
if [[ ! -f "$LEDGER" ]]; then
  {
    printf '# Swarm Full-Flow E2E Gap Ledger\n\n'
    printf '| ID | Status | Severity | Subsystem | Current behavior | Desired behavior | Closed by |\n'
    printf '|---|---|---|---|---|---|---|\n'
  } >"$LEDGER"
fi

if grep -Fq "| $ID |" "$LEDGER"; then
  exit 0
fi

printf '| %s | %s | %s | %s | %s | %s | %s |\n' \
  "$ID" "$STATUS" "$SEVERITY" "$SUBSYSTEM" "$CURRENT" "$DESIRED" "$CLOSED_BY" >>"$LEDGER"
