#!/usr/bin/env bash
# Fail fast when the Harness dev environment is polluted with leftovers from
# a prior aborted run. Wired into the mise check/test/monitor preflight gates
# so CI and local runs never build or test on top of stale state.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
readonly ROOT
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
      if (process_kind == "gate" && $0 ~ /(^| )mise run (check|check:scripts|check:agent-assets)( |$)/) { matched = 1 }
      if (process_kind == "gate" && $0 ~ /(^| )mise run test(:| |$)/) { matched = 1 }
      if (process_kind == "gate" && $0 ~ /(^| )mise run monitor:macos:(xcodebuild|build|lint|test|test:scripts|test:agents-e2e|audit|audit:from-ref)( |$)/) { matched = 1 }
      if (process_kind == "gate" && $0 ~ /(^| )bash \.\/scripts\/check(\.sh|-scripts\.sh)( |$)/) { matched = 1 }
      if (process_kind == "gate" && $0 ~ /(^| )\.\/scripts\/cargo-local\.sh (check|clippy|test|run --quiet -- setup agents generate --check)( |$)/) { matched = 1 }
      if (process_kind == "gate" && $0 ~ /(^| )(bash )?apps\/harness-monitor-macos\/Scripts\/(xcodebuild-with-lock|run-quality-gates|test-swift|test-agents-e2e|run-instruments-audit|run-instruments-audit-from-ref)\.sh( |$)/) { matched = 1 }
      if (process_kind == "gate" && $0 ~ /python3 -m unittest discover -s .*apps\/harness-monitor-macos\/Scripts\/tests/) { matched = 1 }
      if (matched == 1) {
        print pid
      }
    }
  '
}

parent_pid() {
  local pid="$1"
  ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' '
}

ancestor_pids() {
  local pid="$1"
  local ppid

  while [[ -n "$pid" ]]; do
    echo "$pid"
    [[ "$pid" == "1" ]] && break
    ppid="$(parent_pid "$pid")"
    [[ -n "$ppid" && "$ppid" != "$pid" ]] || break
    pid="$ppid"
  done
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
  local current_lineage

  current_lineage="$(ancestor_pids "$$")"
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    if printf '%s\n' "$current_lineage" | grep -Fx -- "$pid" >/dev/null; then
      continue
    fi
    cwd="$(process_cwd "$pid")"
    if [[ "$cwd" == "$ROOT" || "$cwd" == "$ROOT/"* ]]; then
      echo "$pid"
    fi
  done < <(matching_process_pids gate)
}

# 1. Orphan local debug harness daemon or bridge processes (leak vector for
#    perf audits or integration tests that crashed mid-run before cleanup ran).
orphans="$(matching_process_pids debug)"
if [[ -n "$orphans" ]]; then
  stale+=("orphan local debug harness processes: $(echo "$orphans" | tr '\n' ' ')")
fi

repo_gate_workers="$(repo_gate_pids)"
if [[ -n "$repo_gate_workers" ]]; then
  stale+=("repo-local gate helpers still running: $(echo "$repo_gate_workers" | tr '\n' ' ')")
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
