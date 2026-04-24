#!/usr/bin/env bash
# Shared scan primitives for stale Harness dev state.
# Consumers must set STALE_SCAN_ROOT (absolute repo path) before sourcing.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'error: stale-scan.sh must be sourced, not executed directly\n' >&2
  exit 1
fi

if [[ -z "${STALE_SCAN_ROOT:-}" ]]; then
  printf 'error: STALE_SCAN_ROOT must be set before sourcing stale-scan.sh\n' >&2
  return 1
fi

# shellcheck disable=SC2034  # consumed by scripts that source this lib
readonly STALE_SCAN_APP_GROUP_ID="Q498EB36N4.io.harnessmonitor"
# shellcheck disable=SC2034  # consumed by scripts that source this lib
readonly STALE_SCAN_GROUP_CONTAINER_ROOT="$HOME/Library/Group Containers/$STALE_SCAN_APP_GROUP_ID/harness/daemon"
# shellcheck disable=SC2034  # consumed by scripts that source this lib
readonly STALE_SCAN_APPLICATION_SUPPORT_ROOT="$HOME/Library/Application Support/harness/daemon"

# Single cached ps snapshot. Callers may force-refresh between kill cycles.
_stale_scan_ps_snapshot=""

stale_scan_refresh_ps() {
  _stale_scan_ps_snapshot="$(ps -Ao pid=,ppid=,etime=,command=)"
}

stale_scan_ensure_ps() {
  [[ -n "$_stale_scan_ps_snapshot" ]] || stale_scan_refresh_ps
}

# Print pids whose ps line matches the requested bucket:
#   build - any cargo-built harness daemon/bridge under target/{debug,release,dev/*/(debug|release)}
#   live  - installed harness daemon serve / bridge start on PATH
#   gate  - repo-local build/test/lint runners driven by mise or scripts/
stale_scan_matching_pids() {
  local process_kind="$1"
  stale_scan_ensure_ps
  printf '%s\n' "$_stale_scan_ps_snapshot" | awk -v process_kind="$process_kind" '
    {
      pid = $1
      $1 = ""; $2 = ""; $3 = ""
      sub(/^ +/, "", $0)
      matched = 0
      if (process_kind == "build" && $0 ~ /target\/(debug|release|dev\/[^ ]+\/(debug|release))\/harness (daemon|bridge)( |$)/) matched = 1
      if (process_kind == "live"  && $0 ~ /(^|\/)harness (daemon serve|bridge start)( |$)/) matched = 1
      if (process_kind == "gate") {
        if ($0 ~ /(^| )mise run (check|check:scripts|check:agent-assets)( |$)/) matched = 1
        if ($0 ~ /(^| )mise run test(:| |$)/) matched = 1
        if ($0 ~ /(^| )mise run monitor:macos:(xcodebuild|build|lint|test|test:scripts|test:agents-e2e|audit|audit:from-ref)( |$)/) matched = 1
        if ($0 ~ /(^| )bash \.\/scripts\/check(\.sh|-scripts\.sh)( |$)/) matched = 1
        if ($0 ~ /(^| )\.\/scripts\/cargo-local\.sh (check|clippy|test|run --quiet -- setup agents generate --check)( |$)/) matched = 1
        if ($0 ~ /(^| )(bash )?apps\/harness-monitor-macos\/Scripts\/(xcodebuild-with-lock|run-quality-gates|test-swift|test-agents-e2e|run-instruments-audit|run-instruments-audit-from-ref)\.sh( |$)/) matched = 1
        if ($0 ~ /python3 -m unittest discover -s .*apps\/harness-monitor-macos\/Scripts\/tests/) matched = 1
      }
      if (matched) print pid
    }
  '
}

# Print "PID ELAPSED COMMAND" for a pid, or nothing if it is gone.
stale_scan_pid_describe() {
  local pid="$1"
  stale_scan_ensure_ps
  printf '%s\n' "$_stale_scan_ps_snapshot" | awk -v target="$pid" '
    $1 == target {
      etime = $3
      sub(/^ *[0-9]+ +[0-9]+ +[^ ]+ +/, "", $0)
      printf "%s  %s  %s\n", target, etime, $0
      exit
    }
  '
}

stale_scan_root_lock_holder_pids() {
  local root="$1"
  local lock_path
  [[ -d "$root" ]] || return 0
  for lock_path in "$root/daemon.lock" "$root/bridge.lock"; do
    [[ -e "$lock_path" ]] || continue
    lsof -t "$lock_path" 2>/dev/null || true
  done | sort -u
}

# pid -> ppid map from cached snapshot.
_stale_scan_ppid_map=""

stale_scan_ppid_map() {
  if [[ -z "$_stale_scan_ppid_map" ]]; then
    stale_scan_ensure_ps
    _stale_scan_ppid_map="$(printf '%s\n' "$_stale_scan_ps_snapshot" | awk '{print $1":"$2}')"
  fi
  printf '%s\n' "$_stale_scan_ppid_map"
}

stale_scan_parent_pid() {
  local pid="$1"
  stale_scan_ppid_map | awk -F: -v target="$pid" '$1 == target { print $2; exit }'
}

stale_scan_ancestor_pids() {
  local pid="$1"
  local ppid
  while [[ -n "$pid" ]]; do
    echo "$pid"
    [[ "$pid" == "1" ]] && break
    ppid="$(stale_scan_parent_pid "$pid")"
    [[ -n "$ppid" && "$ppid" != "$pid" ]] || break
    pid="$ppid"
  done
}

stale_scan_process_cwd() {
  local pid="$1"
  lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1
}

# Gate-helper pids whose cwd is inside STALE_SCAN_ROOT and which are not in
# the reference_pid's ancestor chain (so we never flag ourselves).
stale_scan_repo_gate_pids() {
  local reference_pid="${1:-$$}"
  local current_lineage pid cwd

  current_lineage="$(stale_scan_ancestor_pids "$reference_pid")"
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    if printf '%s\n' "$current_lineage" | grep -Fx -- "$pid" >/dev/null; then
      continue
    fi
    cwd="$(stale_scan_process_cwd "$pid")"
    if [[ "$cwd" == "$STALE_SCAN_ROOT" || "$cwd" == "$STALE_SCAN_ROOT/"* ]]; then
      echo "$pid"
    fi
  done < <(stale_scan_matching_pids gate)
}

# All stale /tmp bridge artifacts (.sock, .pid, .lock siblings).
stale_scan_tmp_bridge_artifacts() {
  shopt -s nullglob
  local artifacts=(/tmp/h-bridge-*.sock /tmp/h-bridge-*.pid /tmp/h-bridge-*.lock)
  shopt -u nullglob
  (( ${#artifacts[@]} == 0 )) && return 0
  printf '%s\n' "${artifacts[@]}"
}
