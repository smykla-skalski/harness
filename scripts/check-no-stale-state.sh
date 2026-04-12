#!/usr/bin/env bash
# Fail fast when the Harness dev environment is polluted with leftovers from
# a prior aborted run. Wired into the mise check/test/monitor preflight gates
# so CI and local runs never build or test on top of stale state.
set -euo pipefail

readonly RESET_HINT="run 'mise run clean:stale' to reset"
readonly APP_GROUP_ID="Q498EB36N4.io.harnessmonitor"
readonly GROUP_CONTAINER_ROOT="$HOME/Library/Group Containers/$APP_GROUP_ID/harness/daemon"
readonly APPLICATION_SUPPORT_ROOT="$HOME/Library/Application Support/harness/daemon"

stale=()

matching_process_pids() {
  local process_kind="$1"

  ps -Ao pid=,command= | awk -v process_kind="$process_kind" '
    {
      pid = $1
      $1 = ""
      sub(/^ +/, "", $0)
      matched = 0
      if (process_kind == "debug" && $0 ~ /target\/(debug|dev\/.*\/debug)\/harness (daemon|bridge)/) {
        matched = 1
      }
      if (process_kind == "live" && $0 ~ /(^|\/)harness (daemon serve|bridge start)( |$)/) {
        matched = 1
      }
      if (matched == 1) {
        print pid
      }
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

# 1. Orphan local debug harness daemon or bridge processes (leak vector for
#    perf audits or integration tests that crashed mid-run before cleanup ran).
orphans="$(matching_process_pids debug)"
if [[ -n "$orphans" ]]; then
  stale+=("orphan local debug harness processes: $(echo "$orphans" | tr '\n' ' ')")
fi

# 1b. Live installed/manual harness bridge or daemon processes are stale only
#     when they still hold the well-known daemon/bridge locks for the user's
#     real Harness roots.
group_lock_holders="$(root_lock_holder_pids "$GROUP_CONTAINER_ROOT")"
if [[ -n "$group_lock_holders" ]]; then
  stale+=("live harness lock holders in $GROUP_CONTAINER_ROOT: $(echo "$group_lock_holders" | tr '\n' ' ')")
fi

app_support_lock_holders="$(root_lock_holder_pids "$APPLICATION_SUPPORT_ROOT")"
if [[ -n "$app_support_lock_holders" ]]; then
  stale+=("live harness lock holders in $APPLICATION_SUPPORT_ROOT: $(echo "$app_support_lock_holders" | tr '\n' ' ')")
fi

# 2. Stale /tmp bridge sockets. The sandboxed daemon now uses a Group
#    Container fallback, so anything under /tmp is from before the fix or
#    from an unsandboxed bridge that did not unlink on shutdown.
shopt -s nullglob
tmp_sockets=(/tmp/h-bridge-*.sock)
shopt -u nullglob
if (( ${#tmp_sockets[@]} > 0 )); then
  stale+=("stale /tmp bridge sockets: ${tmp_sockets[*]}")
fi

# Xcode UI silently recreates its default DerivedData HarnessMonitor bundle
# as part of indexing whenever the project is open, so checking that path
# here would fail on every CLI run that follows an IDE session. CLI builds
# always pass `-derivedDataPath` explicitly, so the Xcode UI cache is not a
# workflow hazard. `mise run clean:stale` still scrubs it on demand, and
# `Scripts/generate-project.sh` still scrubs it on every project regen.

if (( ${#stale[@]} > 0 )); then
  {
    echo "error: dev state is stale"
    for item in "${stale[@]}"; do
      echo "  - $item"
    done
    echo "$RESET_HINT"
  } >&2
  exit 1
fi
