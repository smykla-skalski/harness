#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
exec "$ROOT/scripts/install-release-set.sh" aff "$@"
