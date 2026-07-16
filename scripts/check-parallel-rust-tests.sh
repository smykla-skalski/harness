#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SCAN_ROOT="${1:-$ROOT}"

if (( $# > 1 )); then
  printf 'usage: %s [scan-root]\n' "${0##*/}" >&2
  exit 2
fi
if [[ ! -d "$SCAN_ROOT" ]]; then
  printf 'error: parallel Rust test scan root is not a directory: %s\n' "$SCAN_ROOT" >&2
  exit 2
fi
if ! command -v rg >/dev/null 2>&1; then
  printf 'error: ripgrep is required for the parallel Rust test policy\n' >&2
  exit 1
fi

serial_pattern='--test-threads|(RUST_TEST_THREADS|NEXTEST_TEST_THREADS)[[:space:]]*=[[:space:]]*["'\'']?0*1["'\'']?([^0-9]|$)|^[[:space:]]*(test-threads|max-threads)[[:space:]]*=[[:space:]]*["'\'']?0*1["'\'']?([[:space:]#]|$)'
nextest_serial_pattern='nextest[^#\n]*(\\[ \t]*\r?\n[^#\n]*)*(--no-?capture|--nocapture|--jobs([= \t]+)["'\'']?0*1["'\'']?([ \t\\,)\]}]|$)|(^|[ \t])-j([= \t]*)["'\'']?0*1["'\'']?([ \t\\,)\]}]|$))'

scan_args=(
  -n
  --hidden
  --glob '!.git/**'
  --glob '!target/**'
  --glob '*.json'
  --glob '*.py'
  --glob '*.rs'
  --glob '*.sh'
  --glob '*.toml'
  --glob '*.yaml'
  --glob '*.yml'
  --glob '!scripts/check-parallel-rust-tests.sh'
)

set +e
literal_violations="$(rg "${scan_args[@]}" -- "$serial_pattern" "$SCAN_ROOT")"
literal_status=$?
nextest_violations="$(rg -U "${scan_args[@]}" -- "$nextest_serial_pattern" "$SCAN_ROOT")"
nextest_status=$?
set -e

if (( literal_status > 1 || nextest_status > 1 )); then
  printf 'error: failed to scan for serialized Rust test configuration\n' >&2
  exit 2
fi
if (( literal_status == 0 || nextest_status == 0 )); then
  violations="$literal_violations"
  if [[ -n "$nextest_violations" ]]; then
    if [[ -n "$violations" ]]; then
      violations+=$'\n'
    fi
    violations+="$nextest_violations"
  fi
  printf 'error: Rust tests must use parallel scheduling and process/resource isolation:\n%s\n' \
    "$violations" >&2
  exit 1
fi
