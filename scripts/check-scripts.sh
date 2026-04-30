#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

run_quiet_step() {
  local label="$1"
  shift

  local step_timeout_seconds="${HARNESS_CHECK_SCRIPTS_STEP_TIMEOUT_SECONDS:-90}"
  if [[ ! "$step_timeout_seconds" =~ ^[0-9]+$ ]] || (( step_timeout_seconds < 1 )); then
    printf 'error: HARNESS_CHECK_SCRIPTS_STEP_TIMEOUT_SECONDS must be a positive integer (got %s)\n' \
      "$step_timeout_seconds" >&2
    return 1
  fi

  local log_path
  log_path="$(mktemp "${TMPDIR:-/tmp}/check-scripts.XXXXXX")"

  if python3 - "$step_timeout_seconds" "$@" >"$log_path" 2>&1 <<'PY'
import os
import signal
import subprocess
import sys

timeout_seconds = int(sys.argv[1])
command = sys.argv[2:]

if not command:
    print("missing command", file=sys.stderr)
    sys.exit(2)

process = subprocess.Popen(command, start_new_session=True)
try:
    process.wait(timeout=timeout_seconds)
except subprocess.TimeoutExpired:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
    print(f"error: timed out after {timeout_seconds}s", file=sys.stderr)
    sys.exit(124)

sys.exit(process.returncode)
PY
  then
    printf 'ok: %s\n' "$label"
    rm -f "$log_path"
    return 0
  fi

  local step_status=$?
  if (( step_status == 124 )); then
    printf 'error: %s timed out after %ss\n' "$label" "$step_timeout_seconds" >&2
  else
    printf 'error: %s failed\n' "$label" >&2
  fi
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
monitor_python_fast_tests=()

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
  for test_path in "${monitor_python_tests[@]}"; do
    case "$(basename -- "$test_path")" in
      test_xcodebuild_with_lock.py|test_test_swift.py)
        ;;
      *)
        monitor_python_fast_tests+=("$test_path")
        ;;
    esac
  done
  if (( ${#monitor_python_fast_tests[@]} > 0 )); then
    run_quiet_step \
      "monitor python script tests (fast subset)" \
      python3 -m unittest "${monitor_python_fast_tests[@]}"
  fi
fi

run_quiet_step "run-step shell tests" "$ROOT/scripts/tests/test-run-step.sh"
run_quiet_step "lease-lock shell tests" bash "$ROOT/scripts/tests/test-lease-lock.sh"
run_quiet_step "mcp shell tests" "$ROOT/scripts/tests/test-mcp-scripts.sh"
if [[ "${HARNESS_CHECK_SCRIPTS_FULL:-0}" == "1" ]]; then
  HARNESS_CHECK_SCRIPTS_STEP_TIMEOUT_SECONDS=180 \
    run_quiet_step "stale-scan shell tests" "$ROOT/scripts/tests/test-stale-scan.sh"
else
  printf 'ok: stale-scan shell tests (skipped in fast mode; set HARNESS_CHECK_SCRIPTS_FULL=1)\n'
fi
run_quiet_step "swarm e2e contract shell tests" "$ROOT/scripts/tests/test-e2e-swarm-contract.sh"
run_quiet_step \
  "recording triage shell tests" \
  "$ROOT/scripts/e2e/recording-triage/tests/run-all.sh"
run_quiet_step "swarm iterate shell tests" "$ROOT/scripts/swarm-iterate/tests/run-all.sh"
run_quiet_step "active ledger shell check" "$ROOT/scripts/swarm-iterate/check-active-ledger.sh"
