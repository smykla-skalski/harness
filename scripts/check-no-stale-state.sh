#!/usr/bin/env bash
# Fail fast when the Harness dev environment is polluted with leftovers from
# a prior aborted run. Wired into the mise check/test/monitor preflight gates
# so CI and local runs never build or test on top of stale state.
#
# When HARNESS_CHECK_AUTOCLEAN=1 is set, a detected pollution triggers one
# automatic clean:stale pass followed by a re-scan. The gate still fails if
# pollution persists after the cleanup, so runaway state is never silently
# absorbed. Healthy parallel agents are not pollution; coordination belongs to
# resource-specific lease locks, not argv/cwd heuristics, but auto-clean must
# still not race other repo-local build/check helpers on shared state.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
readonly ROOT
# shellcheck source=scripts/lib/common-repo-root.sh
source "$ROOT/scripts/lib/common-repo-root.sh"
COMMON_REPO_ROOT="$(resolve_common_repo_root "$ROOT")"
readonly COMMON_REPO_ROOT
STALE_SCAN_ROOT="$ROOT"
STALE_SCAN_COMMON_REPO_ROOT="$COMMON_REPO_ROOT"
export STALE_SCAN_ROOT STALE_SCAN_COMMON_REPO_ROOT
# shellcheck source=scripts/lib/stale-scan.sh
source "$ROOT/scripts/lib/stale-scan.sh"
# shellcheck source=scripts/lib/lease-lock.sh
LEASE_LOCK_DIR="$COMMON_REPO_ROOT/tmp/.stale-state-cleanup.lock"
LEASE_LOCK_RESOURCE="stale-state-cleanup:${COMMON_REPO_ROOT}"
LEASE_LOCK_WAITER_ID="check-stale-$$"
source "$ROOT/scripts/lib/lease-lock.sh"

readonly RESET_HINT="run 'mise run clean:stale' to reset (or re-run with HARNESS_CHECK_AUTOCLEAN=1)"
# Allow tests to redirect autoclean to a sandbox-safe stub. Production runs
# always resolve this to scripts/clean-stale-state.sh.
readonly CLEAN_SCRIPT="${HARNESS_CHECK_CLEAN_SCRIPT:-$ROOT/scripts/clean-stale-state.sh}"
stale_lines=()

should_skip_live_daemon_lock_holder_check() {
  [[ "${HARNESS_CHECK_ALLOW_DAEMON_LOCK_HOLDERS:-0}" == "1" ]]
}

cleanup_stale_check_lease() {
  lease_lock_cleanup
}

emit_pid_block() {
  local label="$1"
  local pids="$2"
  [[ -n "$pids" ]] || return 0
  echo "$label" >&2
  local pid desc
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    desc="$(stale_scan_pid_describe "$pid")"
    [[ -n "$desc" ]] || desc="$pid  ?  (no ps entry)"
    echo "  - $desc" >&2
  done <<<"$pids"
}

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

  # 1b. Parentless xcodebuild-with-lock wrapper shells with no surviving lease
  #     metadata are dead wrappers left behind by aborted runs.
  local monitor_wrapper_orphans
  monitor_wrapper_orphans="$(stale_scan_orphan_monitor_wrapper_pids)"
  append_pid_block "orphan xcodebuild wrapper shells with no lease metadata" "$monitor_wrapper_orphans"

  # 2. Live installed harness daemon/bridge processes only count as stale
  #    when they still hold the well-known locks under the real Harness roots.
  if ! should_skip_live_daemon_lock_holder_check; then
    local group_lock_holders app_support_lock_holders
    group_lock_holders="$(stale_scan_root_lock_holder_pids "$STALE_SCAN_GROUP_CONTAINER_ROOT")"
    append_pid_block "live harness lock holders in $STALE_SCAN_GROUP_CONTAINER_ROOT" "$group_lock_holders"
    app_support_lock_holders="$(stale_scan_root_lock_holder_pids "$STALE_SCAN_APPLICATION_SUPPORT_ROOT")"
    append_pid_block "live harness lock holders in $STALE_SCAN_APPLICATION_SUPPORT_ROOT" "$app_support_lock_holders"
  fi

  # 3. /tmp bridge artifacts. Sandboxed daemon uses Group Container fallback;
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

  # 4. Orphan SQLite sidecars under daemon roots where harness.db is gone.
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

  # 5. Stale swarm e2e worktrees and branches. Failed full-flow runs preserve
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

  # 6. Foreign listener on the Codex WS port.
  local port foreign_ws
  port="$(stale_scan_codex_ws_port)"
  foreign_ws="$(stale_scan_foreign_tcp_listeners "$port")"
  append_pid_block "non-harness processes listening on Codex WS port $port" "$foreign_ws"

  # 7. launchd agent drift (program path gone but service still loaded).
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
  # Tests and tightly-scoped diagnostics can opt out so they can exercise the
  # autoclean branches deterministically even if unrelated repo-local helpers
  # are alive on the host. Normal repo flows leave this unset.
  if [[ "${HARNESS_CHECK_IGNORE_REPO_GATE_HELPERS:-0}" != "1" ]]; then
    repo_gate_pids="$(stale_scan_repo_gate_pids "$$")"
    if [[ -n "$repo_gate_pids" ]]; then
      echo "error: auto-clean blocked while repo-local gate helpers are still running" >&2
      echo "shared cleanup must not overlap active repo-local build/check helpers" >&2
      emit_pid_block "repo-local gate helpers still running:" "$repo_gate_pids"
      report_stale
      exit 1
    fi
  fi

  trap cleanup_stale_check_lease EXIT
  lease_lock_acquire

  {
    echo "check:stale detected pollution; HARNESS_CHECK_AUTOCLEAN=1 is set, running clean:stale..."
    echo "--- initial pollution ---"
    for line in "${stale_lines[@]}"; do
      echo "  $line"
    done
    echo "---"
  } >&2
  if ! env HARNESS_STALE_CLEANUP_LEASE_HELD=1 "$CLEAN_SCRIPT" >&2; then
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
