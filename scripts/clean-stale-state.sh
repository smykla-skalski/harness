#!/usr/bin/env bash
# One-shot reset for a polluted Harness dev environment.
# Preserves user data: harness.db, auth-token, manifest.json, events.jsonl.
# Wipes everything a stale dev run can leak: orphan processes, /tmp sockets,
# and bridge state files. Xcode UI's default DerivedData bundle is left alone
# so regens and resets do not destroy its fetched SourcePackages cache.
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

readonly MONITOR_APP_PATTERN='/Harness Monitor[.]app/Contents/MacOS/Harness Monitor'
readonly LAUNCHD_LABEL="io.harnessmonitor.daemon"

signal_pids() {
  local signal="$1"
  shift
  local pid
  for pid in "$@"; do
    [[ -n "$pid" ]] || continue
    kill "-$signal" "$pid" 2>/dev/null || true
  done
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

cleanup_stale_lease() {
  if declare -F lease_lock_cleanup >/dev/null; then
    lease_lock_cleanup
  fi
}

acquire_stale_cleanup_lease() {
  if [[ "${HARNESS_STALE_CLEANUP_LEASE_HELD:-0}" == "1" ]]; then
    return 0
  fi

  # shellcheck source=scripts/lib/lease-lock.sh
  LEASE_LOCK_DIR="$COMMON_REPO_ROOT/tmp/.stale-state-cleanup.lock"
  LEASE_LOCK_RESOURCE="stale-state-cleanup:${COMMON_REPO_ROOT}"
  LEASE_LOCK_WAITER_ID="clean-stale-$$"
  source "$ROOT/scripts/lib/lease-lock.sh"
  trap cleanup_stale_lease EXIT
  lease_lock_acquire
}

block_live_repo_gate_helpers() {
  local repo_gate_pids
  if [[ "${HARNESS_CHECK_IGNORE_REPO_GATE_HELPERS:-0}" == "1" ]]; then
    return 0
  fi

  stale_scan_refresh_ps
  repo_gate_pids="$(stale_scan_repo_gate_pids "$$")"
  if [[ -z "$repo_gate_pids" ]]; then
    return 0
  fi

  echo "error: clean:stale blocked while repo-local gate helpers are still running" >&2
  echo "shared cleanup must not overlap active repo-local build/check helpers" >&2
  emit_pid_block "repo-local gate helpers still running:" "$repo_gate_pids"
  exit 1
}

quit_monitor_app() {
  if ! pgrep -f "$MONITOR_APP_PATTERN" >/dev/null 2>&1; then
    return
  fi
  echo "quitting Harness Monitor app..."
  /usr/bin/osascript -e 'tell application "Harness Monitor" to quit' >/dev/null 2>&1 || true
  local waited=0
  while (( waited < 5 )) && pgrep -f "$MONITOR_APP_PATTERN" >/dev/null 2>&1; do
    sleep 1
    waited=$((waited + 1))
  done
  if pgrep -f "$MONITOR_APP_PATTERN" >/dev/null 2>&1; then
    echo "  graceful quit timed out; sending SIGTERM"
    pkill -TERM -f "$MONITOR_APP_PATTERN" 2>/dev/null || true
  fi
}

stop_launchd_daemon() {
  local uid
  uid="$(id -u)"
  if ! launchctl print "gui/$uid/$LAUNCHD_LABEL" >/dev/null 2>&1; then
    return
  fi
  echo "stopping launchd daemon $LAUNCHD_LABEL..."
  launchctl bootout "gui/$uid/$LAUNCHD_LABEL" 2>/dev/null || true
}

kill_orphan_harness_processes() {
  local pids=()
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(stale_scan_matching_pids build)
  (( ${#pids[@]} > 0 )) || return 0

  echo "killing orphan local cargo-built harness processes..."
  signal_pids TERM "${pids[@]}"
  sleep 1
  signal_pids KILL "${pids[@]}"
}

orphan_monitor_wrapper_lock_dirs() {
  local pids=("$@")
  local pid desc derived_data_path
  for pid in "${pids[@]}"; do
    [[ -n "$pid" ]] || continue
    desc="$(stale_scan_pid_describe "$pid")"
    [[ -n "$desc" ]] || continue
    derived_data_path="$(stale_scan_monitor_wrapper_derived_data_path "$desc")"
    [[ -n "$derived_data_path" ]] || continue
    printf '%s\n' "$derived_data_path/.xcodebuild.lock"
  done
}

remove_orphan_monitor_wrapper_lock_dirs() {
  local lock_dirs=("$@")
  local lock_dir
  for lock_dir in "${lock_dirs[@]}"; do
    [[ -n "$lock_dir" && -d "$lock_dir" ]] || continue
    if stale_scan_xcodebuild_lock_has_live_work "$lock_dir"; then
      echo "skipping $lock_dir; lock metadata still points to live xcodebuild work"
      continue
    fi
    rm -rf "$lock_dir"
  done
}

kill_orphan_monitor_wrapper_processes() {
  stale_scan_refresh_ps
  local pids=()
  local lock_dirs=()
  local pid lock_dir
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(stale_scan_orphan_monitor_wrapper_pids)
  (( ${#pids[@]} > 0 )) || return 0

  while IFS= read -r lock_dir; do
    [[ -n "$lock_dir" ]] && lock_dirs+=("$lock_dir")
  done < <(orphan_monitor_wrapper_lock_dirs "${pids[@]}")

  echo "killing orphan xcodebuild wrapper shells..."
  signal_pids TERM "${pids[@]}"
  sleep 1
  signal_pids KILL "${pids[@]}"
  stale_scan_refresh_ps
  remove_orphan_monitor_wrapper_lock_dirs "${lock_dirs[@]}"
}

kill_live_harness_processes() {
  local root="$1"
  local pids=()
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(stale_scan_root_lock_holder_pids "$root")
  (( ${#pids[@]} > 0 )) || return 0

  echo "stopping live harness lock holders in $root..."
  signal_pids TERM "${pids[@]}"
  sleep 1

  pids=()
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(stale_scan_root_lock_holder_pids "$root")
  (( ${#pids[@]} > 0 )) || return 0

  echo "force-stopping stubborn harness lock holders in $root..."
  signal_pids KILL "${pids[@]}"
}

kill_orphan_codex_app_servers() {
  local port
  port="$(stale_scan_codex_ws_port)"
  local pids=()
  local pid
  stale_scan_refresh_ps
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(stale_scan_codex_app_server_listener_pids "$port")
  (( ${#pids[@]} > 0 )) || return 0

  echo "stopping orphan codex app-server listener(s) on port $port..."
  signal_pids TERM "${pids[@]}"
  sleep 1

  stale_scan_refresh_ps
  pids=()
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(stale_scan_codex_app_server_listener_pids "$port")
  (( ${#pids[@]} > 0 )) || return 0

  echo "force-stopping stubborn codex app-server listener(s) on port $port..."
  signal_pids KILL "${pids[@]}"
}

remove_tmp_bridge_artifacts() {
  local artifacts=()
  local artifact
  while IFS= read -r artifact; do
    [[ -n "$artifact" ]] && artifacts+=("$artifact")
  done < <(stale_scan_tmp_bridge_artifacts)
  (( ${#artifacts[@]} > 0 )) || return 0
  echo "removing ${#artifacts[@]} stale /tmp bridge artifact(s)..."
  rm -f "${artifacts[@]}"
}

wipe_bridge_state_in_root() {
  local root="$1"
  [[ -d "$root" ]] || return 0
  local removed=0
  local name
  for name in bridge.json bridge.lock bridge-config.json bridge.sock; do
    if [[ -e "$root/$name" ]]; then
      rm -f "$root/$name"
      removed=$((removed + 1))
    fi
  done
  if (( removed > 0 )); then
    echo "  wiped $removed bridge artifact(s) in $root"
  fi
}

wipe_stale_bridge_state() {
  echo "wiping stale bridge state files..."
  wipe_bridge_state_in_root "$STALE_SCAN_GROUP_CONTAINER_ROOT"
  wipe_bridge_state_in_root "$STALE_SCAN_APPLICATION_SUPPORT_ROOT"
}

# Remove orphan SQLite sidecars (harness.db-wal, harness.db-shm) when the DB
# itself has already been deleted. SQLite rebuilds sidecars on next open, and
# leaving them behind re-materializes pre-wipe WAL frames on first connect.
remove_orphan_sqlite_sidecars_in_root() {
  local root="$1"
  [[ -d "$root" ]] || return 0
  local paths=()
  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] && paths+=("$path")
  done < <(stale_scan_orphan_sqlite_sidecars "$root")
  (( ${#paths[@]} > 0 )) || return 0
  echo "  removing ${#paths[@]} orphan SQLite sidecar(s) in $root"
  rm -f "${paths[@]}"
}

remove_orphan_sqlite_sidecars() {
  echo "sweeping orphan SQLite sidecars..."
  remove_orphan_sqlite_sidecars_in_root "$STALE_SCAN_GROUP_CONTAINER_ROOT"
  remove_orphan_sqlite_sidecars_in_root "$STALE_SCAN_APPLICATION_SUPPORT_ROOT"
}

remove_stale_swarm_e2e_worktrees() {
  local entries=()
  local entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && entries+=("$entry")
  done < <(stale_scan_swarm_e2e_worktrees)

  local path branch
  if (( ${#entries[@]} > 0 )); then
    for entry in "${entries[@]}"; do
      path="${entry%%$'\t'*}"
      branch="${entry#*$'\t'}"
      if [[ "$path" == "$entry" || -z "$path" || -z "$branch" ]]; then
        continue
      fi
      echo "removing stale swarm e2e worktree $branch..."
      git -C "$ROOT" worktree remove --force "$path" >/dev/null 2>&1 || true
    done
  fi

  git -C "$ROOT" worktree prune >/dev/null 2>&1 || true

  local branches=()
  while IFS= read -r branch; do
    [[ -n "$branch" ]] && branches+=("$branch")
  done < <(stale_scan_swarm_e2e_branches)

  if (( ${#branches[@]} > 0 )); then
    for branch in "${branches[@]}"; do
      stale_scan_is_swarm_e2e_branch "$branch" || continue
      echo "deleting stale swarm e2e branch $branch..."
      git -C "$ROOT" branch -D "$branch" >/dev/null 2>&1 || true
    done
  fi
}

acquire_stale_cleanup_lease
block_live_repo_gate_helpers

quit_monitor_app
stop_launchd_daemon
kill_orphan_harness_processes
kill_orphan_monitor_wrapper_processes
kill_live_harness_processes "$STALE_SCAN_GROUP_CONTAINER_ROOT"
kill_live_harness_processes "$STALE_SCAN_APPLICATION_SUPPORT_ROOT"
kill_orphan_codex_app_servers
remove_tmp_bridge_artifacts
wipe_stale_bridge_state
remove_orphan_sqlite_sidecars
remove_stale_swarm_e2e_worktrees

echo "clean:stale complete"
