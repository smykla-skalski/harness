#!/usr/bin/env bash
# One-shot reset for a polluted Harness dev environment.
# Preserves user data: harness.db, auth-token, manifest.json, events.jsonl.
# Wipes everything a stale dev run can leak: orphan processes, /tmp sockets,
# and bridge state files. Xcode UI's default DerivedData bundle is left alone
# so regens and resets do not destroy its fetched SourcePackages cache.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
readonly ROOT
readonly APP_GROUP_ID="Q498EB36N4.io.harnessmonitor"
readonly GROUP_CONTAINER_ROOT="$HOME/Library/Group Containers/$APP_GROUP_ID/harness/daemon"
readonly APPLICATION_SUPPORT_ROOT="$HOME/Library/Application Support/harness/daemon"
readonly MONITOR_APP_PATTERN='/Harness Monitor[.]app/Contents/MacOS/Harness Monitor'
readonly LAUNCHD_LABEL="io.harnessmonitor.daemon"

kill_matching_processes() {
  local process_kind="$1"
  local label="$2"
  local pids

  pids="$(matching_process_pids "$process_kind")"
  if [[ -z "$pids" ]]; then
    return
  fi

  echo "killing $label..."
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done <<<"$pids"
  sleep 1
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done <<<"$pids"
}

matching_process_pids() {
  local process_kind="$1"

  ps -Ao pid=,command= | awk -v process_kind="$process_kind" '
    {
      pid = $1
      $1 = ""
      sub(/^ +/, "", $0)
      if (process_kind == "debug" && $0 ~ /target\/(debug|dev\/.*\/debug)\/harness (daemon|bridge)/) {
        print pid
      }
      if (process_kind == "gate" && $0 ~ /(^| )mise run (check|check:scripts|check:agent-assets)( |$)/) { print pid }
      if (process_kind == "gate" && $0 ~ /(^| )mise run test(:| |$)/) { print pid }
      if (process_kind == "gate" && $0 ~ /(^| )mise run monitor:macos:(xcodebuild|build|lint|test|test:scripts|test:agents-e2e|audit|audit:from-ref)( |$)/) { print pid }
      if (process_kind == "gate" && $0 ~ /(^| )bash \.\/scripts\/check(\.sh|-scripts\.sh)( |$)/) { print pid }
      if (process_kind == "gate" && $0 ~ /(^| )\.\/scripts\/cargo-local\.sh (check|clippy|test|run --quiet -- setup agents generate --check)( |$)/) { print pid }
      if (process_kind == "gate" && $0 ~ /(^| )(bash )?apps\/harness-monitor-macos\/Scripts\/(xcodebuild-with-lock|run-quality-gates|test-swift|test-agents-e2e|run-instruments-audit|run-instruments-audit-from-ref)\.sh( |$)/) { print pid }
      if (process_kind == "gate" && $0 ~ /python3 -m unittest discover -s .*apps\/harness-monitor-macos\/Scripts\/tests/) { print pid }
    }
  '
}

root_lock_holder_pids() {
  local root="$1"
  local lock_path

  [[ -d "$root" ]] || return 0

  for lock_path in "$root/daemon.lock" "$root/bridge.lock"; do
    [[ -e "$lock_path" ]] || continue
    lsof -t "$lock_path" 2>/dev/null || true
  done | sort -u
}

process_cwd() {
  local pid="$1"
  lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1
}

repo_gate_pids() {
  local pid
  local cwd

  while read -r pid; do
    [[ -n "$pid" ]] || continue
    cwd="$(process_cwd "$pid")"
    if [[ "$cwd" == "$ROOT" || "$cwd" == "$ROOT/"* ]]; then
      echo "$pid"
    fi
  done < <(matching_process_pids gate)
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
  kill_matching_processes debug "orphan local debug harness processes"
}

kill_repo_gate_processes() {
  local pids

  pids="$(repo_gate_pids)"
  if [[ -z "$pids" ]]; then
    return
  fi

  echo "killing repo-local gate helper processes..."
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done <<<"$pids"
  sleep 1

  pids="$(repo_gate_pids)"
  if [[ -z "$pids" ]]; then
    return
  fi

  echo "force-stopping stubborn repo-local gate helper processes..."
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done <<<"$pids"
}

kill_live_harness_processes() {
  local root="$1"
  local pids

  pids="$(root_lock_holder_pids "$root")"
  if [[ -z "$pids" ]]; then
    return
  fi

  echo "stopping live harness lock holders in $root..."
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done <<<"$pids"
  sleep 1

  pids="$(root_lock_holder_pids "$root")"
  if [[ -z "$pids" ]]; then
    return
  fi

  echo "force-stopping stubborn harness lock holders in $root..."
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done <<<"$pids"
}

remove_tmp_bridge_sockets() {
  shopt -s nullglob
  local sockets=(/tmp/h-bridge-*.sock)
  shopt -u nullglob
  if (( ${#sockets[@]} == 0 )); then
    return
  fi
  echo "removing ${#sockets[@]} stale /tmp bridge socket(s)..."
  rm -f "${sockets[@]}"
}

wipe_bridge_state_in_root() {
  local root="$1"
  if [[ ! -d "$root" ]]; then
    return
  fi
  local removed=0
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
  wipe_bridge_state_in_root "$GROUP_CONTAINER_ROOT"
  wipe_bridge_state_in_root "$APPLICATION_SUPPORT_ROOT"
}

quit_monitor_app
stop_launchd_daemon
kill_orphan_harness_processes
kill_repo_gate_processes
kill_live_harness_processes "$GROUP_CONTAINER_ROOT"
kill_live_harness_processes "$APPLICATION_SUPPORT_ROOT"
remove_tmp_bridge_sockets
wipe_stale_bridge_state

echo "clean:stale complete"
