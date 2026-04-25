#!/usr/bin/env bash
# One-shot reset for a polluted Harness dev environment.
# Preserves user data: harness.db, auth-token, manifest.json, events.jsonl.
# Wipes everything a stale dev run can leak: orphan processes, /tmp sockets,
# and bridge state files. Xcode UI's default DerivedData bundle is left alone
# so regens and resets do not destroy its fetched SourcePackages cache.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
readonly ROOT
STALE_SCAN_ROOT="$ROOT"
export STALE_SCAN_ROOT
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

kill_repo_gate_processes() {
  local pids=()
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(stale_scan_repo_gate_pids "$$")
  (( ${#pids[@]} > 0 )) || return 0

  echo "killing repo-local gate helper processes..."
  signal_pids TERM "${pids[@]}"
  sleep 1

  stale_scan_refresh_ps
  pids=()
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(stale_scan_repo_gate_pids "$$")
  (( ${#pids[@]} > 0 )) || return 0

  echo "force-stopping stubborn repo-local gate helper processes..."
  signal_pids KILL "${pids[@]}"
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

quit_monitor_app
stop_launchd_daemon
kill_orphan_harness_processes
kill_repo_gate_processes
kill_live_harness_processes "$STALE_SCAN_GROUP_CONTAINER_ROOT"
kill_live_harness_processes "$STALE_SCAN_APPLICATION_SUPPORT_ROOT"
kill_orphan_codex_app_servers
remove_tmp_bridge_artifacts
wipe_stale_bridge_state
remove_orphan_sqlite_sidecars
remove_stale_swarm_e2e_worktrees

echo "clean:stale complete"
