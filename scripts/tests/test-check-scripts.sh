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
# shellcheck disable=SC2016
require_text "scripts/check-scripts.sh" 'host_os="$(uname -s)"'
# shellcheck disable=SC2016
require_text "scripts/check-scripts.sh" 'case "$host_os" in'
require_text "scripts/check-scripts.sh" 'Scripts/tests/test_*.py'
require_text "scripts/check-scripts.sh" 'check-parallel-rust-tests.sh'
require_text "scripts/check-scripts.sh" 'run-script-test-suite.py'
require_no_text "scripts/check-scripts.sh" 'run_quiet_step'
require_text "scripts/run-script-test-suite.py" 'root python: parallel script runner'
require_text "scripts/run-script-test-suite.py" 'root macOS python: clean stale fsmonitor'
require_text "scripts/run-script-test-suite.py" 'monitor python:'
require_text "scripts/run-script-test-suite.py" 'check-scripts shell'
require_text "scripts/run-script-test-suite.py" 'clean-stale-lanes shell'
require_text "scripts/run-script-test-suite.py" 'swarm e2e contract shell'
require_text "scripts/run-script-test-suite.py" 'e2e triage-run shell'
require_text "scripts/run-script-test-suite.py" 'HARNESS_CHECK_SCRIPTS_FULL'
require_text "scripts/run-script-test-suite.py" 'HARNESS_SCRIPT_TEST_BUDGET_SECONDS'
require_text "scripts/run-script-test-suite.py" 'scenario_symlinked_repo_tmpdir_base_is_rejected'
require_text \
  "scripts/e2e/recording-triage/tests/lib-test.sh" \
  'harness-monitor-e2e tests require macOS'
require_no_text "scripts/e2e/recording-triage/tests/test_act_timing.sh" 'touch -d'
require_no_text "scripts/e2e/recording-triage/tests/test_auto_keyframes.sh" 'touch -d'
require_no_text \
  "scripts/e2e/recording-triage/tests/test_e2e_copy_preserves_mtime.sh" \
  "/usr/bin/stat -f"

set +e
"$ROOT/scripts/check-scripts.sh" --lint extra >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "extra arguments should return usage status 2 (got $status)"

policy_sandbox="$(mktemp -d "${TMPDIR:-/tmp}/parallel-rust-test-policy.XXXXXX")"
policy_probe="$policy_sandbox/probe.toml"
python_policy_probe="$policy_sandbox/probe.py"
cleanup() {
  rm -rf "$policy_sandbox"
}
trap cleanup EXIT

# shellcheck source=scripts/e2e/recording-triage/tests/lib-test.sh
. "$ROOT/scripts/e2e/recording-triage/tests/lib-test.sh"
mtime_probe="$policy_sandbox/portable-mtime.ready"
recording_triage_test_set_mtime "$mtime_probe" "2000-01-02T03:04:05Z"
[[ -f "$mtime_probe" ]] || fail "portable mtime helper should create a missing marker"
[[ "$(recording_triage_test_mtime_seconds "$mtime_probe")" == "946782245" ]] \
  || fail "portable mtime helper should preserve the requested timestamp"

assert_parallel_policy_rejects() {
  local label="$1" probe="$2" output status
  shift 2
  "$@" >"$probe"

  set +e
  output="$("$ROOT/scripts/check-parallel-rust-tests.sh" "$policy_sandbox" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "$label should fail parallel Rust test policy (got $status)"
  grep -Fq "Rust tests must use parallel scheduling" <<<"$output" \
    || fail "$label should report the parallel Rust test policy"
}

assert_parallel_policy_accepts() {
  local label="$1" probe="$2" output status
  shift 2
  "$@" >"$probe"

  set +e
  output="$("$ROOT/scripts/check-parallel-rust-tests.sh" "$policy_sandbox" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "$label should pass parallel Rust test policy: $output"
}

assert_parallel_policy_rejects \
  "single-thread libtest" \
  "$policy_probe" \
  printf '%s%s%s\n' '--test-' 'threads=' '1'
assert_parallel_policy_rejects \
  "single-thread nextest profile" \
  "$policy_probe" \
  printf '%s%s\n' 'test-threads = 0' '1'
assert_parallel_policy_rejects \
  "single-thread Rust environment" \
  "$policy_probe" \
  printf '%s%s%s\n' 'RUST_TEST_THREADS=' "'" "1'"
assert_parallel_policy_rejects \
  "uncaptured same-line nextest" \
  "$policy_probe" \
  printf '%s%s\n' 'nextest run --no' '-capture'
assert_parallel_policy_rejects \
  "single-thread nextest long jobs alias" \
  "$policy_probe" \
  printf '%s%s%s\n' 'nextest run --jobs=' "'" "01'"
assert_parallel_policy_rejects \
  "single-thread nextest short jobs alias" \
  "$policy_probe" \
  printf '%s%s\n' 'nextest run -j 0' '1'
assert_parallel_policy_rejects \
  "single-thread nextest attached jobs alias" \
  "$policy_probe" \
  printf '%s%s\n' 'nextest run -j0' '1'
assert_parallel_policy_rejects \
  "uncaptured multiline nextest" \
  "$policy_probe" \
  printf '%s %s\n%s %s\n%s%s\n' \
  'nextest run' "\\" \
  '  --config-file .config/nextest.toml' "\\" \
  '  --no-' 'capture'
assert_parallel_policy_rejects \
  "single-thread Python nextest command" \
  "$python_policy_probe" \
  printf '%s%s\n' 'command = "cargo nextest run --jobs=0' '1"'

rm -f "$policy_probe" "$python_policy_probe"
assert_parallel_policy_accepts \
  "unrelated no-capture command" \
  "$policy_probe" \
  printf '%s\n%s%s\n' 'nextest run' 'other-runner --no-' 'capture'
