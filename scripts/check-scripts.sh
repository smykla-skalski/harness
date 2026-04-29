#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

run_quiet_step() {
  local label="$1"
  shift

  local log_path
  log_path="$(mktemp "${TMPDIR:-/tmp}/check-scripts.XXXXXX")"
  if "$@" >"$log_path" 2>&1; then
    printf 'ok: %s\n' "$label"
    rm -f "$log_path"
    return 0
  fi

  printf 'error: %s failed\n' "$label" >&2
  cat "$log_path" >&2
  rm -f "$log_path"
  return 1
}

if ! command -v shellcheck >/dev/null 2>&1; then
  printf "error: shellcheck is required. Install tools with \`mise install\`.\n" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf 'error: python3 is required to compile-check scripts/*.py.\n' >&2
  exit 1
fi

shopt -s nullglob

shell_scripts=(
  "$ROOT"/scripts/*.sh
  "$ROOT"/scripts/e2e/*.sh
  "$ROOT"/scripts/e2e/recording-triage/*.sh
  "$ROOT"/scripts/e2e/recording-triage/tests/*.sh
  "$ROOT"/scripts/lib/*.sh
  "$ROOT"/scripts/swarm-iterate/*.sh
  "$ROOT"/scripts/swarm-iterate/tests/*.sh
  "$ROOT"/scripts/tests/*.sh
)
python_scripts=("$ROOT"/scripts/*.py)
monitor_shell_scripts=(
  "$ROOT"/apps/harness-monitor-macos/Scripts/*.sh
  "$ROOT"/apps/harness-monitor-macos/Scripts/lib/*.sh
)
monitor_python_tests=("$ROOT"/apps/harness-monitor-macos/Scripts/tests/*.py)

for script_path in "${shell_scripts[@]}"; do
  bash -n "$script_path"
done
for script_path in "${monitor_shell_scripts[@]}"; do
  bash -n "$script_path"
done

if (( ${#shell_scripts[@]} > 0 )); then
  shellcheck -x "${shell_scripts[@]}"
fi
if (( ${#monitor_shell_scripts[@]} > 0 )); then
  shellcheck -x "${monitor_shell_scripts[@]}"
fi

if (( ${#python_scripts[@]} > 0 )); then
  python3 -m py_compile "${python_scripts[@]}"
fi
if (( ${#monitor_python_tests[@]} > 0 )); then
  python3 -m py_compile "${monitor_python_tests[@]}"
  run_quiet_step \
    "monitor python script tests" \
    python3 -m unittest discover -s "$ROOT/apps/harness-monitor-macos/Scripts/tests" -p 'test_*.py'
fi

run_quiet_step "run-step shell tests" "$ROOT/scripts/tests/test-run-step.sh"
run_quiet_step "lease-lock shell tests" bash "$ROOT/scripts/tests/test-lease-lock.sh"
run_quiet_step "mcp shell tests" "$ROOT/scripts/tests/test-mcp-scripts.sh"
run_quiet_step "stale-scan shell tests" "$ROOT/scripts/tests/test-stale-scan.sh"
run_quiet_step "swarm e2e contract shell tests" "$ROOT/scripts/tests/test-e2e-swarm-contract.sh"
run_quiet_step \
  "recording triage shell tests" \
  "$ROOT/scripts/e2e/recording-triage/tests/run-all.sh"
run_quiet_step "swarm iterate shell tests" "$ROOT/scripts/swarm-iterate/tests/run-all.sh"
run_quiet_step "active ledger shell check" "$ROOT/scripts/swarm-iterate/check-active-ledger.sh"
