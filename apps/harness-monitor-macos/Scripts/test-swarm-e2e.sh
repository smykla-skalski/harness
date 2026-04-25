#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)"
exec "$ROOT/scripts/e2e/swarm-full-flow.sh" --assert "$@"
