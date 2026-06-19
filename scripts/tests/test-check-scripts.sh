#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"

fail() {
  printf 'test-check-scripts: %s\n' "$*" >&2
  exit 1
}

require_absent() {
  local path="$1"
  [[ ! -e "$ROOT/$path" ]] || fail "obsolete helper still exists: $path"
}

require_text() {
  local path="$1"
  local text="$2"
  grep -Fq -- "$text" "$ROOT/$path" || fail "missing '$text' in $path"
}

require_no_text() {
  local path="$1"
  local text="$2"
  if grep -Fq -- "$text" "$ROOT/$path"; then
    fail "unexpected '$text' in $path"
  fi
}

require_absent "scripts/.rename-allow.txt"
require_absent "scripts/check.sh"
require_absent "scripts/rename-dependencies-to-reviews.sh"
require_absent "scripts/rename-files.sh"
require_absent "scripts/validate-reviews-rename.sh"

# Single-quoted arguments assert literal source text in check-scripts.sh.
# shellcheck disable=SC2016
require_text "scripts/check-scripts.sh" '"$ROOT"/scripts/lib/*.py'
# shellcheck disable=SC2016
require_text "scripts/check-scripts.sh" '"$ROOT"/scripts/tests/test_*.py'
require_text "scripts/check-scripts.sh" 'root python script tests'
require_text "scripts/check-scripts.sh" 'check-scripts shell tests'
require_text "scripts/check-scripts.sh" 'clean-stale-lanes shell tests'
require_text "scripts/check-scripts.sh" 'e2e triage-run shell tests'
require_text "scripts/check-scripts.sh" 'HARNESS_CHECK_SCRIPTS_FULL_TIMEOUT_SECONDS'
require_no_text "scripts/check-scripts.sh" 'HARNESS_CHECK_SCRIPTS_STEP_TIMEOUT_SECONDS=180'
