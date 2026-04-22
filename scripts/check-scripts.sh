#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

if ! command -v shellcheck >/dev/null 2>&1; then
  printf "error: shellcheck is required. Install tools with \`mise install\`.\n" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf 'error: python3 is required to compile-check scripts/*.py.\n' >&2
  exit 1
fi

shopt -s nullglob

shell_scripts=("$ROOT"/scripts/*.sh)
python_scripts=("$ROOT"/scripts/*.py)

for script_path in "${shell_scripts[@]}"; do
  bash -n "$script_path"
done

if (( ${#shell_scripts[@]} > 0 )); then
  shellcheck -x "${shell_scripts[@]}"
fi

if (( ${#python_scripts[@]} > 0 )); then
  python3 -m py_compile "${python_scripts[@]}"
fi
