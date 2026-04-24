#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"

# shellcheck source=scripts/lib/run-step.sh
source "$ROOT/scripts/lib/run-step.sh"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/run-step-test-$$.XXXXXX")"
PASS_COUNT=0
FAIL_COUNT=0
FAIL_NAMES=()
CURRENT_TEST=""

cleanup() {
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

log() {
  printf '%s\n' "$*" >&2
}

start_test() {
  CURRENT_TEST="$1"
  log "RUN:  $CURRENT_TEST"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAIL_NAMES+=("$CURRENT_TEST")
  log "  FAIL: $CURRENT_TEST - $*"
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  log "  PASS: $CURRENT_TEST"
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  if grep -Fq -- "$needle" <<<"$haystack"; then
    return 0
  fi
  fail "missing '$needle' in output: $haystack"
  return 1
}

scenario_failed_step_preserves_output_and_reports_reason() {
  start_test "failed step preserves child output and reports reason"
  local output status=0
  output="$(harness_run_step "sample check" bash -c \
    'printf "child stdout\n"; printf "child stderr\n" >&2; exit 7' 2>&1)" || status=$?

  if (( status != 7 )); then
    fail "expected status 7, got $status (output: $output)"
    return
  fi

  local ok=1
  assert_contains "child stdout" "$output" || ok=0
  assert_contains "child stderr" "$output" || ok=0
  assert_contains "error: sample check failed" "$output" || ok=0
  assert_contains "command: bash -c" "$output" || ok=0
  assert_contains "reason: exit status 7" "$output" || ok=0
  if (( ok )); then pass; fi
}

scenario_status_summary_names_signals() {
  start_test "status summary names signal exits"
  local summary
  summary="$(harness_status_summary 143)"
  if [[ "$summary" == *"signal"* && "$summary" == *"15"* ]]; then
    pass
  else
    fail "expected signal summary for 143, got: $summary"
  fi
}

scenario_cargo_local_reports_failed_cargo_command() {
  start_test "cargo-local reports failed cargo command"
  local fake_bin="$SANDBOX/bin"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/cargo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-V" ]]; then
  printf 'cargo 1.99.0-test\n'
  exit 0
fi
printf 'fake cargo stderr\n' >&2
exit 42
EOF
  chmod +x "$fake_bin/cargo"

  local output status=0
  output="$(PATH="$fake_bin:$PATH" TMPDIR="$SANDBOX/" \
    CODEX_SESSION_ID="run-step-test-$$" "$ROOT/scripts/cargo-local.sh" test --lib 2>&1)" \
    || status=$?

  if (( status != 42 )); then
    fail "expected status 42, got $status (output: $output)"
    return
  fi

  local ok=1
  assert_contains "fake cargo stderr" "$output" || ok=0
  assert_contains "error: cargo-local command failed" "$output" || ok=0
  assert_contains "command: cargo test --lib" "$output" || ok=0
  assert_contains "reason: exit status 42" "$output" || ok=0
  if (( ok )); then pass; fi
}

run_all() {
  scenario_failed_step_preserves_output_and_reports_reason
  scenario_status_summary_names_signals
  scenario_cargo_local_reports_failed_cargo_command
}

run_all

log "----"
log "run-step tests: $PASS_COUNT passed, $FAIL_COUNT failed"
if (( FAIL_COUNT > 0 )); then
  log "failures:"
  for name in "${FAIL_NAMES[@]}"; do
    log "  - $name"
  done
  exit 1
fi
