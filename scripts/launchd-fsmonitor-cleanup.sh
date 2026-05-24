#!/usr/bin/env bash
# Periodic fsmonitor cleanup, invoked by ~/Library/LaunchAgents/
# com.smykla.harness.fsmonitor-cleanup.plist.
#
# Two passes:
#   1. clean-stale-fsmonitor.sh --apply      kills orphan + redundant daemons
#   2. disable-fsmonitor-dormant.sh --apply  flips dormant repos to
#                                            core.fsmonitor=false so they
#                                            stop respawning daemons
#
# Output goes to a rotating log under ~/Library/Logs/. launchd reruns this
# weekly (see the plist).
set -uo pipefail

REPO_ROOT="${HARNESS_REPO_ROOT:-$HOME/Projects/github.com/smykla-skalski/harness}"
LOG_DIR="${HARNESS_FSMONITOR_LOG_DIR:-$HOME/Library/Logs/HarnessFsmonitorCleanup}"
mkdir -p "$LOG_DIR"

# Rotate by keeping the last 8 weekly logs.
log_file="$LOG_DIR/cleanup-$(/bin/date +%Y%m%d-%H%M%S).log"
{
  printf '=== fsmonitor cleanup run at %s ===\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'pid=%s host=%s\n' "$$" "$(/bin/hostname)"

  if [[ ! -d "$REPO_ROOT" ]]; then
    printf 'fatal: HARNESS_REPO_ROOT=%s does not exist\n' "$REPO_ROOT" >&2
    exit 1
  fi

  printf '\n--- pass 1: clean-stale-fsmonitor --apply ---\n'
  bash "$REPO_ROOT/scripts/clean-stale-fsmonitor.sh" --apply || true

  printf '\n--- pass 2: disable-fsmonitor-dormant --apply ---\n'
  bash "$REPO_ROOT/scripts/disable-fsmonitor-dormant.sh" --apply || true

  printf '\n=== done at %s ===\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$log_file" 2>&1

# Trim older logs.
/bin/ls -1t "$LOG_DIR"/cleanup-*.log 2>/dev/null | /usr/bin/tail -n +9 | while IFS= read -r old; do
  /bin/rm -f "$old"
done
