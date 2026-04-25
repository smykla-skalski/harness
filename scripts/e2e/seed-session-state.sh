#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/lib.sh
. "$SCRIPT_DIR/lib.sh"

DATA_HOME="${HARNESS_E2E_DATA_HOME:-${XDG_DATA_HOME:-${TMPDIR:-/tmp}/harness-swarm-e2e-data}}"
AGENT_ID=""
STALL_SECONDS=""

while (($#)); do
  case "$1" in
    --data-home) DATA_HOME="$2"; shift 2 ;;
    --agent) AGENT_ID="$2"; shift 2 ;;
    --stall-seconds) STALL_SECONDS="$2"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

mkdir -p "$DATA_HOME/harness" "$DATA_HOME/e2e-sync" "$DATA_HOME/e2e-ledger"

if [[ -n "$AGENT_ID" && -n "$STALL_SECONDS" ]]; then
  e2e_write_kv_marker \
    "$DATA_HOME/e2e-ledger/stall-$AGENT_ID.env" \
    "agent_id=$AGENT_ID" \
    "stall_seconds=$STALL_SECONDS"
fi

jq -nc --arg dh "$DATA_HOME" '{data_home: $dh, seeded: true}'
