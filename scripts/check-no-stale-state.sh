#!/usr/bin/env bash
# Fail fast when the Harness dev environment is polluted with leftovers from
# a prior aborted run. Wired into the mise check/test/monitor preflight gates
# so CI and local runs never build or test on top of stale state.
set -euo pipefail

readonly RESET_HINT="run 'mise run clean:stale' to reset"

stale=()

# 1. Orphan target/debug harness daemon or bridge processes (leak vector for
#    perf audits that crashed mid-run before cleanup_host_processes fired).
orphans="$(pgrep -f 'target/debug/harness (daemon|bridge)' 2>/dev/null || true)"
if [[ -n "$orphans" ]]; then
  stale+=("orphan target/debug/harness processes: $(echo "$orphans" | tr '\n' ' ')")
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

# 3. Non-approved Xcode DerivedData HarnessMonitor bundles. The repo allows
#    only tmp/xcode-derived and tmp/perf/harness-monitor-instruments/xcode-derived
#    (see apps/harness-monitor-macos/CLAUDE.md). Anything else is stale.
shopt -s nullglob
stray_derived=("$HOME/Library/Developer/Xcode/DerivedData/HarnessMonitor-"*)
shopt -u nullglob
if (( ${#stray_derived[@]} > 0 )); then
  stale+=("non-approved DerivedData bundles: ${stray_derived[*]}")
fi

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
