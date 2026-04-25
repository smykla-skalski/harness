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
#   gate  - repo-local check/lint/build runners driven by mise or scripts/
stale_scan_matching_pids() {
  local process_kind="$1"
  stale_scan_ensure_ps
  awk -v process_kind="$process_kind" '
    {
      pid = $1
      $1 = ""; $2 = ""; $3 = ""
      sub(/^ +/, "", $0)
      matched = 0
      if (process_kind == "build" && $0 ~ /target\/(debug|release|dev\/[^ ]+\/(debug|release))\/harness (daemon|bridge)( |$)/) matched = 1
      if (process_kind == "live"  && $0 ~ /(^|\/)harness (daemon serve|bridge start)( |$)/) matched = 1
      if (process_kind == "gate") {
        if ($0 ~ /(^| )mise run (check|check:scripts|check:agent-assets)( |$)/) matched = 1
        if ($0 ~ /(^| )mise run monitor:macos:(xcodebuild|build|lint|audit|audit:from-ref)( |$)/) matched = 1
        if ($0 ~ /(^| )bash \.\/scripts\/check(\.sh|-scripts\.sh)( |$)/) matched = 1
        if ($0 ~ /(^| )\.\/scripts\/cargo-local\.sh (check|clippy|run --quiet -- setup agents generate --check)( |$)/) matched = 1
        if ($0 ~ /(^| )(bash )?apps\/harness-monitor-macos\/Scripts\/(xcodebuild-with-lock|run-quality-gates|run-instruments-audit|run-instruments-audit-from-ref)\.sh( |$)/) matched = 1
      }
      if (matched) print pid
    }
  ' <<<"$_stale_scan_ps_snapshot"
}

# Print "PID ELAPSED COMMAND" for a pid, or nothing if it is gone.
stale_scan_pid_describe() {
  local pid="$1"
  stale_scan_ensure_ps
  awk -v target="$pid" '
    $1 == target {
      etime = $3
      sub(/^ *[0-9]+ +[0-9]+ +[^ ]+ +/, "", $0)
      printf "%s  %s  %s\n", target, etime, $0
      exit
    }
  ' <<<"$_stale_scan_ps_snapshot"
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
    _stale_scan_ppid_map="$(awk '{print $1":"$2}' <<<"$_stale_scan_ps_snapshot")"
  fi
  printf '%s\n' "$_stale_scan_ppid_map"
}

stale_scan_parent_pid() {
  local pid="$1"
  awk -F: -v target="$pid" '$1 == target { print $2; exit }' <<<"$(stale_scan_ppid_map)"
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
# All membership checks use herestrings to avoid `printf | grep -q` SIGPIPE
# races under pipefail.
stale_scan_repo_gate_pids() {
  local reference_pid="${1:-$$}"
  local current_lineage pid cwd

  current_lineage="$(stale_scan_ancestor_pids "$reference_pid")"
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    if grep -Fxq -- "$pid" <<<"$current_lineage"; then
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

# Emit orphan SQLite sidecar paths (.db-wal, .db-shm) under a daemon root
# where harness.db itself has been deleted. SQLite recreates sidecars on next
# open; leaving them behind keeps pre-wipe WAL frames discoverable and causes
# "database disk image is malformed" on first open.
stale_scan_orphan_sqlite_sidecars() {
  local root="$1"
  [[ -d "$root" ]] || return 0
  local db="$root/harness.db"
  if [[ -e "$db" ]]; then
    return 0
  fi
  local sidecar
  for sidecar in "$root/harness.db-wal" "$root/harness.db-shm"; do
    if [[ -e "$sidecar" ]]; then
      echo "$sidecar"
    fi
  done
  return 0
}

stale_scan_is_swarm_e2e_branch() {
  local branch="$1"
  [[ "$branch" == harness/sess-e2e-swarm-* ]]
}

stale_scan_swarm_e2e_worktrees_from_porcelain() {
  awk '
    /^worktree / {
      path = substr($0, 10)
      next
    }
    /^branch refs\/heads\/harness\/sess-e2e-swarm-/ {
      branch = $0
      sub(/^branch refs\/heads\//, "", branch)
      if (path != "") {
        print path "\t" branch
      }
      next
    }
    /^$/ {
      path = ""
    }
  '
}

stale_scan_swarm_e2e_worktrees() {
  git -C "$STALE_SCAN_ROOT" worktree list --porcelain 2>/dev/null \
    | stale_scan_swarm_e2e_worktrees_from_porcelain
}

stale_scan_swarm_e2e_branches() {
  git -C "$STALE_SCAN_ROOT" branch --list 'harness/sess-e2e-swarm-*' \
    --format='%(refname:short)' 2>/dev/null
}

# Resolve the Codex WS port the daemon is expected to bind.
# HARNESS_CODEX_WS_PORT mirrors src/daemon/bridge/types.rs::CODEX_BRIDGE_PORT_ENV.
stale_scan_codex_ws_port() {
  printf '%s\n' "${HARNESS_CODEX_WS_PORT:-4500}"
}

# Emit pids holding LISTEN on the given TCP port that are NOT a Harness
# component. Ours = anything matched by the build or live buckets, plus the
# Harness Monitor.app process. Everything else is a conflict.
#
# Membership checks use herestrings (<<<) instead of `printf | grep -q` because
# grep -q closes stdin on first match, which SIGPIPEs the writer; callers run
# under `set -o pipefail` and would abort mid-scan.
stale_scan_foreign_tcp_listeners() {
  local port="$1"
  command -v lsof >/dev/null 2>&1 || return 0
  stale_scan_ensure_ps
  local ours_build ours_live ours
  ours_build="$(stale_scan_matching_pids build)"
  ours_live="$(stale_scan_matching_pids live)"
  ours="$(printf '%s\n%s\n' "$ours_build" "$ours_live" | sort -u)"

  local listeners
  listeners="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | sort -u || true)"
  [[ -n "$listeners" ]] || return 0

  local pid desc
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if grep -Fxq -- "$pid" <<<"$ours"; then
      continue
    fi
    desc="$(stale_scan_pid_describe "$pid")"
    if [[ "$desc" == *"Harness Monitor"* ]]; then
      continue
    fi
    echo "$pid"
  done <<<"$listeners"
}

# Emit pids for Codex app-server listeners on the given port. These are spawned
# by the host bridge and can survive as parentless processes when the bridge is
# terminated by a stale-state reset instead of a graceful shutdown.
stale_scan_codex_app_server_listener_pids() {
  local port="$1"
  command -v lsof >/dev/null 2>&1 || return 0
  stale_scan_ensure_ps

  local listeners
  listeners="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | sort -u || true)"
  [[ -n "$listeners" ]] || return 0

  local pid desc
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    desc="$(stale_scan_pid_describe "$pid")"
    if [[ "$desc" == *"codex app-server"* ]]; then
      echo "$pid"
    fi
  done <<<"$listeners"
}

# Pure parser for `launchctl print` text. Given a label and the command output,
# emit a single drift line if the service's "program = <path>" target is
# missing from disk. Split out so tests can cover drift reporting without
# touching the user's real launchd state.
stale_scan_launchd_drift_from_output() {
  local label="$1"
  local print_output="$2"
  [[ -n "$print_output" ]] || return 0
  local program_path
  program_path="$(awk '
    /^[[:space:]]+program = / {
      sub(/^[[:space:]]+program = /, "", $0)
      print
      exit
    }
  ' <<<"$print_output")"
  if [[ -n "$program_path" && ! -e "$program_path" ]]; then
    echo "$label: program missing: $program_path"
  fi
}

# Query launchctl for the given GUI-domain label and report drift.
stale_scan_launchd_drift() {
  local label="${1:-io.harnessmonitor.daemon}"
  command -v launchctl >/dev/null 2>&1 || return 0
  local uid
  uid="$(id -u)"
  local print_output
  print_output="$(launchctl print "gui/$uid/$label" 2>/dev/null)" || return 0
  stale_scan_launchd_drift_from_output "$label" "$print_output"
}
