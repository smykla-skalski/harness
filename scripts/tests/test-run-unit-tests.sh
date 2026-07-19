#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/run-unit-tests-test.XXXXXX")"
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
  mise trust --untrust "$SANDBOX/.mise.toml" >/dev/null 2>&1 || true
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL: %s\n' "$*" >&2
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS: %s\n' "$1" >&2
}

# Extract the real test:unit task block so the sandboxed mise.toml can never
# drift from the actual repo wiring the fix is supposed to cover.
awk '
  /^\[tasks\."test:unit"\]$/ { capture = 1 }
  capture && /^\[tasks\./ && !/^\[tasks\."test:unit"\]$/ { capture = 0 }
  capture { print }
' "$ROOT/.mise.toml" >"$SANDBOX/.mise.toml"

if ! grep -q 'run = "\./scripts/run-unit-tests\.sh"' "$SANDBOX/.mise.toml"; then
  fail "test:unit task no longer delegates to scripts/run-unit-tests.sh; extracted block: $(<"$SANDBOX/.mise.toml")"
fi

mkdir -p "$SANDBOX/scripts"
cp "$ROOT/scripts/run-unit-tests.sh" "$SANDBOX/scripts/run-unit-tests.sh"
chmod +x "$SANDBOX/scripts/run-unit-tests.sh"

calls_dir="$SANDBOX/calls"

cat >"$SANDBOX/scripts/cargo-local.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
calls_dir="$calls_dir"
mkdir -p "\$calls_dir"
next=1
while [[ -e "\$calls_dir/call-\$next" ]]; do
  next=\$((next + 1))
done
printf '%s\n' "\$@" >"\$calls_dir/call-\$next"
EOF
chmod +x "$SANDBOX/scripts/cargo-local.sh"

# Unconditional pass-through stand-in: the real run-linux-only.sh's own
# OS-detection behavior is covered by test-run-linux-only.sh; here we only
# care that scripts/run-unit-tests.sh forwards "$@" through it unchanged on
# every host, including macOS where the real script would skip the call.
cat >"$SANDBOX/scripts/run-linux-only.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "$@"
EOF
chmod +x "$SANDBOX/scripts/run-linux-only.sh"

(cd "$SANDBOX" && mise trust >/dev/null)

run_task() {
  (cd "$SANDBOX" && mise run test:unit "$@")
}

reset_calls() {
  rm -rf "$calls_dir"
}

calls_snapshot() {
  find "$calls_dir" -maxdepth 1 -name 'call-*' -print0 2>/dev/null \
    | xargs -0 cat -- 2>/dev/null || true
}

assert_call_count() {
  local expected="$1" actual
  [[ -d "$calls_dir" ]] || { (( expected == 0 )); return; }
  actual="$(find "$calls_dir" -maxdepth 1 -name 'call-*' 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$actual" == "$expected" ]]
}

assert_call_matches() {
  local call_number="$1"
  shift
  local expected actual
  [[ -f "$calls_dir/call-$call_number" ]] || return 1
  expected="$(printf '%s\n' "$@")"
  actual="$(<"$calls_dir/call-$call_number")"
  [[ "$actual" == "$expected" ]]
}

scenario_no_arguments_preserves_all_three_groups() {
  reset_calls
  if ! run_task >"$SANDBOX/no-args.log" 2>&1; then
    fail "no-argument test:unit run failed: $(<"$SANDBOX/no-args.log")"
    return
  fi
  if assert_call_count 3 \
    && assert_call_matches 1 \
      nextest run --config-file .config/nextest.toml --user-config-file none -p harness --lib --features full-runtime \
    && assert_call_matches 2 \
      nextest run --config-file .config/nextest.toml --user-config-file none -p harness-command -p harness-daemon-client -p harness-protocol -p harness-systemd-protocol -p harness-telemetry -p harness-testkit \
    && assert_call_matches 3 \
      nextest run --config-file .config/nextest.toml --user-config-file none -p harness-systemd; then
    pass "no-argument invocation still exercises all three package groups unfiltered"
  else
    fail "no-argument invocation did not preserve the original three-group invocations: $(calls_snapshot)"
  fi
}

scenario_forwards_simple_filter_to_every_group() {
  reset_calls
  if ! run_task -- -E 'test(=path::to::test)' >"$SANDBOX/simple-filter.log" 2>&1; then
    fail "filtered test:unit run failed: $(<"$SANDBOX/simple-filter.log")"
    return
  fi
  if assert_call_count 3 \
    && assert_call_matches 1 \
      nextest run --config-file .config/nextest.toml --user-config-file none -p harness --lib --features full-runtime -E 'test(=path::to::test)' \
    && assert_call_matches 2 \
      nextest run --config-file .config/nextest.toml --user-config-file none -p harness-command -p harness-daemon-client -p harness-protocol -p harness-systemd-protocol -p harness-telemetry -p harness-testkit -E 'test(=path::to::test)' \
    && assert_call_matches 3 \
      nextest run --config-file .config/nextest.toml --user-config-file none -p harness-systemd -E 'test(=path::to::test)'; then
    pass "a simple nextest filter reaches every package group, including harness-systemd"
  else
    fail "simple nextest filter was not forwarded to every group: $(calls_snapshot)"
  fi
}

scenario_preserves_multiword_single_token_filter() {
  reset_calls
  local filter='test(~foo::bar) and not test(~baz)'
  if ! run_task -- -E "$filter" >"$SANDBOX/multiword-filter.log" 2>&1; then
    fail "multi-word filter test:unit run failed: $(<"$SANDBOX/multiword-filter.log")"
    return
  fi
  if assert_call_count 3 \
    && assert_call_matches 1 \
      nextest run --config-file .config/nextest.toml --user-config-file none -p harness --lib --features full-runtime -E "$filter" \
    && assert_call_matches 3 \
      nextest run --config-file .config/nextest.toml --user-config-file none -p harness-systemd -E "$filter"; then
    pass "a filter containing spaces survives as a single token in every group"
  else
    fail "multi-word single-token filter was split or mangled: $(calls_snapshot)"
  fi
}

scenario_rejects_shell_injection_attempt() {
  reset_calls
  local marker="$SANDBOX/pwned"
  rm -f "$marker"
  local payload="\$(touch $marker)"
  if ! run_task -- "$payload" >"$SANDBOX/injection.log" 2>&1; then
    fail "injection-attempt test:unit run failed: $(<"$SANDBOX/injection.log")"
    return
  fi
  if [[ -e "$marker" ]]; then
    fail "shell metacharacter payload executed instead of being forwarded literally"
    return
  fi
  if assert_call_count 3 \
    && assert_call_matches 1 \
      nextest run --config-file .config/nextest.toml --user-config-file none -p harness --lib --features full-runtime "$payload"; then
    pass "a shell metacharacter payload is forwarded as an inert literal argument"
  else
    fail "injection-attempt payload was not forwarded as an inert literal argument: $(calls_snapshot)"
  fi
}

scenario_no_arguments_preserves_all_three_groups
scenario_forwards_simple_filter_to_every_group
scenario_preserves_multiword_single_token_filter
scenario_rejects_shell_injection_attempt

printf 'run-unit-tests tests: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT" >&2
(( FAIL_COUNT == 0 ))
