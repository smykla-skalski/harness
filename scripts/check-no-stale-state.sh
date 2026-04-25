#!/usr/bin/env bash
# Fail fast when the Harness dev environment is polluted with leftovers from
# a prior aborted run. Wired into the mise check/test/monitor preflight gates
# so CI and local runs never build or test on top of stale state.
#
# When HARNESS_CHECK_AUTOCLEAN=1 is set, a detected pollution triggers one
# automatic clean:stale pass followed by a re-scan. The gate still fails if
# pollution persists after the cleanup, so runaway state is never silently
# absorbed.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
readonly ROOT
STALE_SCAN_ROOT="$ROOT"
export STALE_SCAN_ROOT
# shellcheck source=scripts/lib/stale-scan.sh
source "$ROOT/scripts/lib/stale-scan.sh"

readonly RESET_HINT="run 'mise run clean:stale' to reset (or re-run with HARNESS_CHECK_AUTOCLEAN=1)"
# Allow tests to redirect autoclean to a sandbox-safe stub. Production runs
# always resolve this to scripts/clean-stale-state.sh.
readonly CLEAN_SCRIPT="${HARNESS_CHECK_CLEAN_SCRIPT:-$ROOT/scripts/clean-stale-state.sh}"

stale_lines=()

append_pid_block() {
  local label="$1"
  local pids="$2"
  [[ -n "$pids" ]] || return 0
  stale_lines+=("$label:")
  local pid desc
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    desc="$(stale_scan_pid_describe "$pid")"
    [[ -n "$desc" ]] || desc="$pid  ?  (no ps entry)"
    stale_lines+=("  - $desc")
  done <<<"$pids"
}

append_path_block() {
  local label="$1"
  shift
  (( $# > 0 )) || return 0
  stale_lines+=("$label:")
  local path
  for path in "$@"; do
    stale_lines+=("  - $path")
  done
}

collect_stale_lines() {
  stale_scan_refresh_ps
  stale_lines=()

  # 1. Orphan cargo-built harness daemon/bridge processes from any target dir
  #    (covers debug, release, and dev/<triple>/{debug,release}).
  local orphans
  orphans="$(stale_scan_matching_pids build)"
  append_pid_block "orphan local cargo-built harness processes" "$orphans"

  # 2. Repo-local gate workers still rooted in this checkout.
  local repo_gate_workers
  repo_gate_workers="$(stale_scan_repo_gate_pids "$$")"
  append_pid_block "repo-local gate helpers still running" "$repo_gate_workers"

  # 3. Live installed harness daemon/bridge processes only count as stale
  #    when they still hold the well-known locks under the real Harness roots.
  local group_lock_holders app_support_lock_holders
  group_lock_holders="$(stale_scan_root_lock_holder_pids "$STALE_SCAN_GROUP_CONTAINER_ROOT")"
  append_pid_block "live harness lock holders in $STALE_SCAN_GROUP_CONTAINER_ROOT" "$group_lock_holders"
  app_support_lock_holders="$(stale_scan_root_lock_holder_pids "$STALE_SCAN_APPLICATION_SUPPORT_ROOT")"
  append_pid_block "live harness lock holders in $STALE_SCAN_APPLICATION_SUPPORT_ROOT" "$app_support_lock_holders"

  # 4. /tmp bridge artifacts. Sandboxed daemon uses Group Container fallback;
  #    anything in /tmp is from before the sandbox fix or from an unsandboxed
  #    bridge that did not unlink on shutdown. Sweep .sock, .pid, and .lock.
  local tmp_artifacts=()
  local artifact
  while IFS= read -r artifact; do
    [[ -n "$artifact" ]] && tmp_artifacts+=("$artifact")
  done < <(stale_scan_tmp_bridge_artifacts)
  if (( ${#tmp_artifacts[@]} > 0 )); then
    append_path_block "stale /tmp bridge artifacts" "${tmp_artifacts[@]}"
  fi

  # 5. Orphan SQLite sidecars under daemon roots where harness.db is gone.
  local wal_orphans=()
  local sidecar
  while IFS= read -r sidecar; do
    [[ -n "$sidecar" ]] && wal_orphans+=("$sidecar")
  done < <(
    stale_scan_orphan_sqlite_sidecars "$STALE_SCAN_GROUP_CONTAINER_ROOT"
    stale_scan_orphan_sqlite_sidecars "$STALE_SCAN_APPLICATION_SUPPORT_ROOT"
  )
  if (( ${#wal_orphans[@]} > 0 )); then
    append_path_block "orphan SQLite sidecars (harness.db is gone)" "${wal_orphans[@]}"
  fi

  # 6. Stale swarm e2e worktrees and branches. Failed full-flow runs preserve
  #    state for debugging; the harness/sess-e2e-swarm-* refs are owned by that
  #    lane and must not poison future runs.
  local swarm_worktrees=()
  local swarm_entry
  while IFS= read -r swarm_entry; do
    [[ -n "$swarm_entry" ]] && swarm_worktrees+=("$swarm_entry")
  done < <(stale_scan_swarm_e2e_worktrees)
  if (( ${#swarm_worktrees[@]} > 0 )); then
    append_path_block "stale swarm e2e worktrees" "${swarm_worktrees[@]}"
  fi

  local swarm_branches=()
  local swarm_branch
  while IFS= read -r swarm_branch; do
    [[ -n "$swarm_branch" ]] && swarm_branches+=("$swarm_branch")
  done < <(stale_scan_swarm_e2e_branches)
  if (( ${#swarm_branches[@]} > 0 )); then
    append_path_block "stale swarm e2e branches" "${swarm_branches[@]}"
  fi

  # 7. Foreign listener on the Codex WS port.
  local port foreign_ws
  port="$(stale_scan_codex_ws_port)"
  foreign_ws="$(stale_scan_foreign_tcp_listeners "$port")"
  append_pid_block "non-harness processes listening on Codex WS port $port" "$foreign_ws"

  # 8. launchd agent drift (program path gone but service still loaded).
  local drift_line
  while IFS= read -r drift_line; do
    [[ -n "$drift_line" ]] || continue
    stale_lines+=("launchd drift:")
    stale_lines+=("  - $drift_line")
  done < <(stale_scan_launchd_drift)
}

report_stale() {
  {
    echo "error: dev state is stale"
    local line
    for line in "${stale_lines[@]}"; do
      echo "  $line"
    done
    echo "$RESET_HINT"
  } >&2
}

# Xcode UI silently recreates its default DerivedData HarnessMonitor bundle
# as part of indexing whenever the project is open, so checking that path
# here would fail on every CLI run that follows an IDE session. CLI builds
# always pass `-derivedDataPath` explicitly, so the Xcode UI cache is not a
# workflow hazard. `mise run clean:stale` still scrubs it on demand.

collect_stale_lines
if (( ${#stale_lines[@]} == 0 )); then
  exit 0
fi

if [[ "${HARNESS_CHECK_AUTOCLEAN:-}" == "1" ]]; then
  {
    echo "check:stale detected pollution; HARNESS_CHECK_AUTOCLEAN=1 is set, running clean:stale..."
    echo "--- initial pollution ---"
    for line in "${stale_lines[@]}"; do
      echo "  $line"
    done
    echo "---"
  } >&2
  if ! "$CLEAN_SCRIPT" >&2; then
    echo "error: auto-clean failed; dev state still stale" >&2
    report_stale
    exit 1
  fi
  collect_stale_lines
  if (( ${#stale_lines[@]} == 0 )); then
    echo "check:stale clean passed after auto-clean." >&2
    exit 0
  fi
  echo "error: auto-clean did not resolve all pollution" >&2
fi

report_stale
exit 1
