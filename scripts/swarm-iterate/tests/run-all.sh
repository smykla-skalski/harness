#!/usr/bin/env bash
set -euo pipefail

# Discover and run every test_*.sh under scripts/swarm-iterate/tests/.
# Run serially; fail fast on first failure.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
shopt -s nullglob

failures=0
ran=0
for test_path in "$SCRIPT_DIR"/test_*.sh; do
  ran=$((ran + 1))
  printf '== running %s\n' "$(basename -- "$test_path")"
  if ! "$test_path"; then
    failures=$((failures + 1))
    printf '!! failed: %s\n' "$(basename -- "$test_path")" >&2
  fi
done

if (( ran == 0 )); then
  printf 'no swarm-iterate tests discovered under %s\n' "$SCRIPT_DIR" >&2
  exit 1
fi

if (( failures > 0 )); then
  printf '%d swarm-iterate test(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'all %d swarm-iterate tests passed\n' "$ran"
