#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

# shellcheck source=scripts/lib/run-step.sh
source "$ROOT/scripts/lib/run-step.sh"

harness_run_step "stale-state preflight" "$ROOT/scripts/check-no-stale-state.sh"
harness_run_step "version sync check" "$ROOT/scripts/version.sh" check
harness_run_step "script lint and regression checks" "$ROOT/scripts/check-scripts.sh"
harness_run_step "cargo check" "$ROOT/scripts/cargo-local.sh" check
harness_run_step "cargo clippy --lib" "$ROOT/scripts/cargo-local.sh" clippy --lib
harness_run_step "generated agent asset check" \
  "$ROOT/scripts/cargo-local.sh" run --quiet -- setup agents generate --check
