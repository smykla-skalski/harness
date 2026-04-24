#!/usr/bin/env bash
# Fail fast when the Harness dev environment is polluted with leftovers from
# a prior aborted run. Wired into the mise check/test/monitor preflight gates
# so CI and local runs never build or test on top of stale state.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
readonly ROOT
STALE_SCAN_ROOT="$ROOT"
export STALE_SCAN_ROOT
# shellcheck source=scripts/lib/stale-scan.sh
source "$ROOT/scripts/lib/stale-scan.sh"

readonly RESET_HINT="run 'mise run clean:stale' to reset"

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

# 1. Orphan cargo-built harness daemon/bridge processes from any target dir
#    (covers debug, release, and dev/<triple>/{debug,release}).
orphans="$(stale_scan_matching_pids build)"
append_pid_block "orphan local cargo-built harness processes" "$orphans"

# 2. Repo-local gate workers still rooted in this checkout.
repo_gate_workers="$(stale_scan_repo_gate_pids "$$")"
append_pid_block "repo-local gate helpers still running" "$repo_gate_workers"

# 3. Live installed harness daemon/bridge processes only count as stale when
#    they still hold the well-known locks under the real Harness roots.
group_lock_holders="$(stale_scan_root_lock_holder_pids "$STALE_SCAN_GROUP_CONTAINER_ROOT")"
append_pid_block "live harness lock holders in $STALE_SCAN_GROUP_CONTAINER_ROOT" "$group_lock_holders"

app_support_lock_holders="$(stale_scan_root_lock_holder_pids "$STALE_SCAN_APPLICATION_SUPPORT_ROOT")"
append_pid_block "live harness lock holders in $STALE_SCAN_APPLICATION_SUPPORT_ROOT" "$app_support_lock_holders"

# 4. /tmp bridge artifacts. Sandboxed daemon uses Group Container fallback;
#    anything in /tmp is from before the sandbox fix or from an unsandboxed
#    bridge that did not unlink on shutdown. Sweep .sock, .pid, and .lock.
tmp_artifacts=()
while IFS= read -r artifact; do
  [[ -n "$artifact" ]] || continue
  tmp_artifacts+=("$artifact")
done < <(stale_scan_tmp_bridge_artifacts)
if (( ${#tmp_artifacts[@]} > 0 )); then
  append_path_block "stale /tmp bridge artifacts" "${tmp_artifacts[@]}"
fi

# Xcode UI silently recreates its default DerivedData HarnessMonitor bundle
# as part of indexing whenever the project is open, so checking that path
# here would fail on every CLI run that follows an IDE session. CLI builds
# always pass `-derivedDataPath` explicitly, so the Xcode UI cache is not a
# workflow hazard. `mise run clean:stale` still scrubs it on demand, and
# `Scripts/generate-project.sh` still scrubs it on every project regen.

if (( ${#stale_lines[@]} > 0 )); then
  {
    echo "error: dev state is stale"
    for line in "${stale_lines[@]}"; do
      echo "  $line"
    done
    echo "$RESET_HINT"
  } >&2
  exit 1
fi
