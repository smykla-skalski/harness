#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
host_os="$(uname -s)"
case "$host_os" in
  Darwin|Linux)
    ;;
  *)
    printf 'error: unsupported script-test host OS: %s\n' "$host_os" >&2
    exit 1
    ;;
esac

if (( $# > 1 )); then
  printf 'usage: %s [--all|--lint|--tests]\n' "${0##*/}" >&2
  exit 2
fi

mode="${1:---all}"
case "$mode" in
  --all|--lint|--tests)
    ;;
  *)
    printf 'usage: %s [--all|--lint|--tests]\n' "${0##*/}" >&2
    exit 2
    ;;
esac

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
python_scripts=(
  "$ROOT"/scripts/*.py
  "$ROOT"/scripts/lib/*.py
  "$ROOT"/scripts/tests/test_*.py
)
monitor_shell_scripts=(
  "$ROOT"/apps/harness-monitor/ci_scripts/*.sh
  "$ROOT"/apps/harness-monitor/Scripts/*.sh
  "$ROOT"/apps/harness-monitor/Scripts/lib/*.sh
)
monitor_python_scripts=(
  "$ROOT"/apps/harness-monitor/Scripts/*.py
  "$ROOT"/apps/harness-monitor/Scripts/lib/*.py
)
monitor_python_tests=("$ROOT"/apps/harness-monitor/Scripts/tests/test_*.py)

if ! command -v python3 >/dev/null 2>&1; then
  printf 'error: python3 is required to compile-check or test scripts/*.py.\n' >&2
  exit 1
fi

if [[ "$mode" != "--tests" ]]; then
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf "error: shellcheck is required. Install tools with \`mise install\`.\n" >&2
    exit 1
  fi
  if ! command -v rg >/dev/null 2>&1; then
    printf "error: ripgrep is required. Install tools with \`mise install\`.\n" >&2
    exit 1
  fi

  "$ROOT/scripts/check-parallel-rust-tests.sh"

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
  if (( ${#monitor_python_scripts[@]} > 0 )); then
    python3 -m py_compile "${monitor_python_scripts[@]}"
  fi
  if (( ${#monitor_python_tests[@]} > 0 )); then
    python3 -m py_compile "${monitor_python_tests[@]}"
  fi
fi

if [[ "$mode" != "--lint" ]]; then
  exec python3 "$ROOT/scripts/run-script-test-suite.py" --suite all
fi
