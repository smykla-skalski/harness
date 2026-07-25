#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=scripts/lib/release-set.sh
source "$ROOT/scripts/lib/release-set.sh"

frontend="${HARNESS_PANEL_FRONTEND_DIR:-$ROOT/crates/harness-panel/frontend}"
lockfile="$frontend/package-lock.json"
stamp="$frontend/node_modules/.harness-panel-stamp"
npm="${HARNESS_PANEL_NPM:-npm}"

if [[ ! -f "$lockfile" ]]; then
  printf 'panel frontend lockfile does not exist: %s\n' "$lockfile" >&2
  exit 1
fi

# This lock is independent from the release pipeline even when that pipeline
# spawned the build. Every caller must wait here; inheriting a release lock
# owner would make its child processes participants and let both enter.
unset HARNESS_RELEASE_PIPELINE_LOCK_OWNER_RECORD
HARNESS_RELEASE_PIPELINE_LOCK_DIR="$frontend/.harness-panel-install.lock"
export HARNESS_RELEASE_PIPELINE_LOCK_DIR
release_pipeline_lock_acquire "$frontend"
trap 'release_pipeline_lock_release' EXIT

# Recheck after acquiring the lock. Another build may have completed the
# install while this process was waiting.
if [[ -f "$stamp" ]] && command cmp -s "$lockfile" "$stamp"; then
  exit 0
fi

(
  CDPATH='' command cd -- "$frontend"
  command "$npm" ci --no-audit --no-fund
)

stamp_tmp="$frontend/node_modules/.harness-panel-stamp.$$"
command cp "$lockfile" "$stamp_tmp"
command mv "$stamp_tmp" "$stamp"
