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

STALE_SCAN_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$STALE_SCAN_LIB_DIR/common-repo-root.sh"
# shellcheck source=scripts/lib/process-state.sh
source "$STALE_SCAN_LIB_DIR/process-state.sh"
STALE_SCAN_MONITOR_RUNTIME_PROFILE_LIB="$STALE_SCAN_ROOT/apps/harness-monitor-macos/Scripts/lib/runtime-profile.sh"
if [[ -f "$STALE_SCAN_MONITOR_RUNTIME_PROFILE_LIB" ]]; then
  # shellcheck source=apps/harness-monitor-macos/Scripts/lib/runtime-profile.sh
  source "$STALE_SCAN_MONITOR_RUNTIME_PROFILE_LIB"
  harness_monitor_apply_runtime_profile_environment
fi
STALE_SCAN_COMMON_REPO_ROOT="${STALE_SCAN_COMMON_REPO_ROOT:-$(resolve_common_repo_root "$STALE_SCAN_ROOT")}"

# shellcheck disable=SC2034  # consumed by scripts that source this lib
readonly STALE_SCAN_APP_GROUP_ID="${HARNESS_APP_GROUP_ID:-Q498EB36N4.io.harnessmonitor}"
# shellcheck disable=SC2034  # consumed by scripts that source this lib
readonly STALE_SCAN_GROUP_CONTAINER_ROOT="$HOME/Library/Group Containers/$STALE_SCAN_APP_GROUP_ID/harness/daemon"
# shellcheck disable=SC2034  # consumed by scripts that source this lib
readonly STALE_SCAN_APPLICATION_SUPPORT_ROOT="$HOME/Library/Application Support/harness/daemon"

# Single cached ps snapshot. Callers may force-refresh between kill cycles.
_stale_scan_ps_snapshot=""

stale_scan_is_profile_scoped() {
  [[ -n "${HARNESS_DAEMON_DATA_HOME:-}" || -n "${HARNESS_MONITOR_RUNTIME_PROFILE:-}" ]]
}

stale_scan_daemon_roots() {
  if [[ -n "${HARNESS_DAEMON_DATA_HOME:-}" ]]; then
    printf '%s\n' "$HARNESS_DAEMON_DATA_HOME/harness/daemon"
    return 0
  fi

  printf '%s\n' "$STALE_SCAN_GROUP_CONTAINER_ROOT"
  printf '%s\n' "$STALE_SCAN_APPLICATION_SUPPORT_ROOT"
}

stale_scan_refresh_ps() {
  _stale_scan_ps_snapshot="$(ps -Ao pid=,ppid=,etime=,command=)"
  _stale_scan_ppid_map=""
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
        if ($0 ~ /(^| )mise run monitor:(xcodebuild|build|lint|audit|audit:from-ref)( |$)/) matched = 1
        if ($0 ~ /(^| )bash (([^ ]*\/)?scripts\/check(\.sh|-scripts\.sh))( |$)/) matched = 1
        if ($0 ~ /(^| )\.\/scripts\/cargo-local\.sh (check|clippy|run --quiet -- setup agents generate --check)( |$)/) matched = 1
        if ($0 ~ /(^| )(bash )?([^ ]*\/)?apps\/harness-monitor-macos\/Scripts\/(xcodebuild-with-lock|run-quality-gates|run-instruments-audit|run-instruments-audit-from-ref|test-swift|build-for-testing)\.sh( |$)/) matched = 1
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

stale_scan_monitor_wrapper_derived_data_path() {
  local command_line="$1"
  awk '
    {
      for (i = 1; i <= NF; i += 1) {
        if ($i == "-derivedDataPath" && i < NF) {
          print $(i + 1)
          exit
        }
        if ($i ~ /^-derivedDataPath=/) {
          sub(/^-derivedDataPath=/, "", $i)
          print $i
          exit
        }
      }
    }
  ' <<<"$command_line"
}

stale_scan_orphan_monitor_wrapper_pids() {
  stale_scan_ensure_ps
  local line pid ppid command_line derived_data_path
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pid="$(awk '{print $1}' <<<"$line")"
    ppid="$(awk '{print $2}' <<<"$line")"
    command_line="$(awk '{ $1=""; $2=""; $3=""; sub(/^ +/, "", $0); print }' <<<"$line")"

    [[ "$ppid" == "1" ]] || continue
    [[ "$command_line" == *"xcodebuild-with-lock.sh"* ]] || continue

    derived_data_path="$(stale_scan_monitor_wrapper_derived_data_path "$command_line")"
    if [[ -z "$derived_data_path" ]]; then
      echo "$pid"
      continue
    fi

    if [[ ! -e "$derived_data_path/.xcodebuild.lock/owner/lease.env" \
      && ! -e "$derived_data_path/.xcodebuild.lock/waiters/${pid}.env" ]]; then
      echo "$pid"
    fi
  done <<<"$_stale_scan_ps_snapshot"
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

stale_scan_process_env_value() {
  local pid="$1"
  local key="$2"
  local process_line value

  process_line="$(ps eww -p "$pid" -o command= 2>/dev/null || true)"
  [[ -n "$process_line" ]] || return 1

  value="$(
    awk -v key="$key" '
      {
        pattern = "(^|[[:space:]])" key "="
        if (match($0, pattern)) {
          value = substr($0, RSTART + RLENGTH)
          sub(/[[:space:]].*$/, "", value)
          print value
        }
      }
    ' <<<"$process_line"
  )"
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

stale_scan_current_runtime_profile() {
  if ! declare -F harness_monitor_runtime_profile >/dev/null; then
    return 1
  fi
  harness_monitor_runtime_profile 2>/dev/null || true
}

stale_scan_pid_runtime_profile() {
  local pid="$1"
  local profile

  profile="$(stale_scan_process_env_value "$pid" HARNESS_MONITOR_RUNTIME_PROFILE || true)"
  if [[ -z "$profile" ]] && declare -F harness_monitor_profile_from_path >/dev/null; then
    profile="$(
      harness_monitor_profile_from_path \
        "$(stale_scan_process_env_value "$pid" HARNESS_DAEMON_DATA_HOME || true)" \
        || true
    )"
  fi
  if declare -F harness_monitor_sanitize_profile >/dev/null; then
    profile="$(harness_monitor_sanitize_profile "$profile")"
  fi
  [[ -n "$profile" ]] || return 1
  printf '%s\n' "$profile"
}

stale_scan_pid_harness_lock_paths() {
  local pid="$1"
  lsof -a -p "$pid" -Fn 2>/dev/null \
    | sed -n 's/^n//p' \
    | awk '/(^|\/)harness\/daemon\/(daemon|bridge)\.lock$/ { print }'
}

stale_scan_pid_holds_harness_lock() {
  local pid="$1"
  local lock_path
  while IFS= read -r lock_path; do
    [[ -n "$lock_path" ]] || continue
    return 0
  done < <(stale_scan_pid_harness_lock_paths "$pid")
  return 1
}

# Cargo-built harness daemon/bridge processes are only stale "orphans" when
# they are no longer anchoring a real Harness daemon/bridge root. Live bridges
# started through `monitor:user:bridge:start` still match the build bucket, but
# they must survive clean:stale while holding their lock.
stale_scan_orphan_harness_build_pids() {
  local pid
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    if stale_scan_pid_holds_harness_lock "$pid"; then
      continue
    fi
    echo "$pid"
  done < <(stale_scan_matching_pids build)
}

# Live holders are stale only when they are unscoped. Scope is declared either
# directly via HARNESS_MONITOR_RUNTIME_PROFILE or indirectly via a profile-shaped
# HARNESS_DAEMON_DATA_HOME.
stale_scan_live_lock_holder_is_stale() {
  local pid="$1"
  local profile
  profile="$(stale_scan_pid_runtime_profile "$pid" || true)"
  [[ -z "$profile" ]]
}

stale_scan_root_conflicting_lock_holder_pids() {
  local root="$1"
  local pid
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    if stale_scan_live_lock_holder_is_stale "$pid"; then
      echo "$pid"
    fi
  done < <(stale_scan_root_lock_holder_pids "$root")
}

stale_scan_root_has_live_lock_holder() {
  local root="$1"
  local pid
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    return 0
  done < <(stale_scan_root_lock_holder_pids "$root")
  return 1
}

# Current lane means "same effective runtime scope as this cleanup/check
# invocation". Profile-scoped lanes only match the same profile; unscoped lanes
# only match unscoped holders. This lets the safe cleanup preserve the current
# lane's Codex WS listener without letting unrelated profiled holders mask stale
# shared listeners on the default port.
stale_scan_pid_in_current_lane() {
  local pid="$1"
  local current_profile pid_profile
  current_profile="$(stale_scan_current_runtime_profile || true)"
  pid_profile="$(stale_scan_pid_runtime_profile "$pid" || true)"
  if [[ -n "$current_profile" ]]; then
    [[ "$pid_profile" == "$current_profile" ]]
    return
  fi
  [[ -z "$pid_profile" ]]
}

stale_scan_root_has_current_lane_lock_holder() {
  local root="$1"
  local pid
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    if stale_scan_pid_in_current_lane "$pid"; then
      return 0
    fi
  done < <(stale_scan_root_lock_holder_pids "$root")
  return 1
}

stale_scan_any_root_has_current_lane_lock_holder() {
  local root
  while read -r root; do
    [[ -n "$root" ]] || continue
    if stale_scan_root_has_current_lane_lock_holder "$root"; then
      return 0
    fi
  done < <(stale_scan_daemon_roots)
  return 1
}

stale_scan_gate_pid_conflicts_with_current_lane() {
  local pid="$1"
  local current_profile pid_profile

  if ! stale_scan_is_profile_scoped; then
    return 0
  fi

  current_profile="$(stale_scan_current_runtime_profile)"
  if [[ -z "$current_profile" ]]; then
    return 0
  fi

  pid_profile="$(stale_scan_pid_runtime_profile "$pid" || true)"
  [[ -z "$pid_profile" || "$pid_profile" == "$current_profile" ]]
}

# Gate-helper pids whose cwd is in the same common-root domain and which are
# not in the reference_pid's ancestor chain (so we never flag ourselves).
# Unprofiled maintenance lanes still coordinate across the whole common-root.
# Profile-scoped lanes only conflict with same-profile helpers (or unscoped
# helpers that still target shared checkout state). All membership checks use
# herestrings to avoid `printf | grep -q` SIGPIPE races under pipefail.
stale_scan_process_in_common_repo_root() {
  local path="$1"
  local path_common_root
  [[ -n "$path" ]] || return 1
  path_common_root="$(resolve_common_repo_root "$path" 2>/dev/null || true)"
  [[ -n "$path_common_root" && "$path_common_root" == "$STALE_SCAN_COMMON_REPO_ROOT" ]]
}

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
    if ! stale_scan_process_in_common_repo_root "$cwd"; then
      continue
    fi
    if stale_scan_gate_pid_conflicts_with_current_lane "$pid"; then
      echo "$pid"
    fi
  done < <(stale_scan_matching_pids gate)
}

stale_scan_metadata_value() {
  local metadata_file="$1"
  local key="$2"
  [[ -f "$metadata_file" ]] || return 1
  sed -n "s/^${key}=//p" "$metadata_file" | head -n 1
}

stale_scan_lock_process_alive_from_file() {
  local metadata_file="$1"
  local pid_key="$2"
  local start_key="$3"
  local command_key="$4"
  local process_pid process_start process_command

  process_pid="$(stale_scan_metadata_value "$metadata_file" "$pid_key" || true)"
  [[ "$process_pid" =~ ^[0-9]+$ ]] || return 1
  process_start="$(stale_scan_metadata_value "$metadata_file" "$start_key" || true)"
  process_command="$(stale_scan_metadata_value "$metadata_file" "$command_key" || true)"
  process_state_identity_matches "$process_pid" "$process_start" "$process_command"
}

stale_scan_xcodebuild_lock_has_live_work() {
  local lock_path="$1"
  local owner_file="$lock_path/owner/lease.env"
  local runtime_file="$lock_path/owner/runtime.env"
  local local_hostname owner_hostname runtime_hostname

  local_hostname="$(process_state_hostname)"
  owner_hostname="$(stale_scan_metadata_value "$owner_file" LOCK_HOSTNAME || true)"
  runtime_hostname="$(stale_scan_metadata_value "$runtime_file" LOCK_HOSTNAME || true)"

  if [[ -n "$owner_hostname" && "$owner_hostname" != "$local_hostname" ]]; then
    return 0
  fi
  if [[ -n "$runtime_hostname" && "$runtime_hostname" != "$local_hostname" ]]; then
    return 0
  fi

  if stale_scan_lock_process_alive_from_file \
      "$owner_file" \
      LOCK_PID \
      LOCK_PROCESS_START \
      LOCK_COMMAND; then
    return 0
  fi

  stale_scan_lock_process_alive_from_file \
    "$runtime_file" \
    LOCK_MUTATOR_PID \
    LOCK_MUTATOR_PROCESS_START \
    LOCK_MUTATOR_COMMAND
}

# All stale bridge artifacts (.sock, .pid, .lock siblings). Production scans
# /tmp; tests may override the root to avoid ambient host cleanup races.
stale_scan_tmp_bridge_root() {
  printf '%s\n' "${HARNESS_STALE_SCAN_TMP_ROOT:-/tmp}"
}

stale_scan_tmp_bridge_artifacts() {
  if stale_scan_is_profile_scoped; then
    return 0
  fi
  local bridge_tmp_root
  bridge_tmp_root="$(stale_scan_tmp_bridge_root)"
  shopt -s nullglob
  local artifacts=(
    "$bridge_tmp_root"/h-bridge-*.sock
    "$bridge_tmp_root"/h-bridge-*.pid
    "$bridge_tmp_root"/h-bridge-*.lock
  )
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

  local current_lane_has_live_root=0
  if stale_scan_any_root_has_current_lane_lock_holder; then
    current_lane_has_live_root=1
  fi

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
    if (( current_lane_has_live_root == 1 )) && [[ "$desc" == *"codex app-server"* ]]; then
      continue
    fi
    echo "$pid"
  done <<<"$listeners"
}

# Emit pids for Codex app-server listeners on the given port only when the
# current cleanup/check lane no longer has a live Harness lock holder. A live
# current-lane bridge/daemon is allowed to keep its WS listener in plain
# `clean:stale`; stale parentless listeners are still cleanup targets.
stale_scan_codex_app_server_listener_pids() {
  local port="$1"
  command -v lsof >/dev/null 2>&1 || return 0
  stale_scan_ensure_ps

  if stale_scan_any_root_has_current_lane_lock_holder; then
    return 0
  fi

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
  local label="${1:-${HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL:-io.harnessmonitor.daemon}}"
  command -v launchctl >/dev/null 2>&1 || return 0
  local uid
  uid="$(id -u)"
  local print_output
  print_output="$(launchctl print "gui/$uid/$label" 2>/dev/null)" || return 0
  stale_scan_launchd_drift_from_output "$label" "$print_output"
}
