#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

"$ROOT/scripts/check-no-stale-state.sh"
"$ROOT/scripts/version.sh" check
"$ROOT/scripts/check-scripts.sh"
"$ROOT/scripts/cargo-local.sh" check
"$ROOT/scripts/cargo-local.sh" clippy --lib
"$ROOT/scripts/cargo-local.sh" run --quiet -- setup agents generate --check
