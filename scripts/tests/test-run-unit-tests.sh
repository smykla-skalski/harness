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

# Extract the real broad, focused, and per-group unit-test task blocks so the
# sandboxed mise.toml can never drift from the actual repo wiring under test.
awk '
  function wanted(line) {
    return line == "[tasks.\"test:unit\"]" \
      || line == "[tasks.\"test:unit:harness\"]" \
      || line == "[tasks.\"test:unit:harness-lib\"]" \
      || line == "[tasks.\"test:unit:supporting-crates\"]" \
      || line == "[tasks.\"test:unit:agents\"]" \
      || line == "[tasks.\"test:unit:task-board\"]" \
      || line == "[tasks.\"test:unit:systemd\"]" \
      || line == "[tasks.\"test:unit:daemon\"]" \
      || line == "[tasks.\"test:unit:daemon-bin\"]"
  }
  wanted($0) { capture = 1 }
  capture && /^\[tasks\./ && !wanted($0) { capture = 0 }
  capture { print }
' "$ROOT/.mise.toml" >"$SANDBOX/.mise.toml"

if ! grep -q 'run = "\./scripts/run-unit-tests\.sh"' "$SANDBOX/.mise.toml"; then
  fail "test:unit task no longer delegates to scripts/run-unit-tests.sh; extracted block: $(<"$SANDBOX/.mise.toml")"
fi
if ! grep -q 'run = "\./scripts/cargo-local\.sh test -p harness --lib --features full-runtime"' "$SANDBOX/.mise.toml"; then
  fail "test:unit:harness no longer uses one native root test process; extracted block: $(<"$SANDBOX/.mise.toml")"
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
# Shell-escaped records preserve argument boundaries even when one argument
# contains a newline that would otherwise look like several arguments.
printf '%q\n' "\$@" >"\$calls_dir/call-\$next"
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

run_harness_task() {
  (cd "$SANDBOX" && mise run test:unit:harness "$@")
}

run_group_task() {
  local group_name="$1"; shift
  (cd "$SANDBOX" && mise run "test:unit:$group_name" "$@")
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
  expected="$(printf '%q\n' "$@")"
  actual="$(<"$calls_dir/call-$call_number")"
  [[ "$actual" == "$expected" ]]
}

scenario_no_arguments_preserves_all_groups() {
  reset_calls
  if ! run_task >"$SANDBOX/no-args.log" 2>&1; then
    fail "no-argument test:unit run failed: $(<"$SANDBOX/no-args.log")"
    return
  fi
  if ! assert_call_count 7; then fail "no-arg: wrong call count"; return; fi
  if ! assert_call_matches 1 nextest run --config-file .config/nextest.toml --user-config-file none -p harness --lib --features full-runtime; then fail "no-arg: call-1 mismatch: actual=$(<"$calls_dir/call-1")"; return; fi
  if ! assert_call_matches 2 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-acme-dns -p harness-command -p harness-daemon-acp-probe -p harness-daemon-cli -p harness-daemon-client -p harness-daemon-discovery -p harness-daemon-launchd -p harness-daemon-provider-credentials -p harness-daemon-remote-cli -p harness-daemon-root -p harness-daemon-snapshot -p harness-daemon-state -p harness-daemon-watch -p harness-db-schema -p harness-feature-flags -p harness-hooks -p harness-infra -p harness-kernel -p harness-mcp -p harness-observe -p harness-panel -p harness-policy-graph-store -p harness-protocol -p harness-remote-trust -p harness-reviews -p harness-run -p harness-sybra -p harness-systemd-protocol -p harness-task-board -p harness-task-board-codex-requests -p harness-task-board-provider-sync -p harness-task-board-remote-viewer -p harness-telemetry -p harness-testkit -p harness-timeline -p harness-voice -p harness-workspace; then fail "no-arg: call-2 mismatch"; return; fi
  if ! assert_call_matches 3 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-agents --lib --features bridge-runtime; then fail "no-arg: call-3 mismatch: actual=$(<"$calls_dir/call-3")"; return; fi
  if ! assert_call_matches 4 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-task-board --lib --features daemon-runtime; then fail "no-arg: call-4 mismatch: actual=$(<"$calls_dir/call-4")"; return; fi
  if ! assert_call_matches 5 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-systemd; then fail "no-arg: call-5 mismatch: actual=$(<"$calls_dir/call-5")"; return; fi
  if ! assert_call_matches 6 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon --lib; then fail "no-arg: call-6 mismatch: actual=$(<"$calls_dir/call-6")"; return; fi
  if ! assert_call_matches 7 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon-bin; then fail "no-arg: call-7 mismatch: actual=$(<"$calls_dir/call-7")"; return; fi
  if ! grep -Fq "==> test:unit 1/7: root Harness library" "$SANDBOX/no-args.log"; then fail "no-argument invocation: missing log line for group 1 (harness-lib)"; return; fi
  if ! grep -Fq "==> test:unit 2/7: supporting workspace crates" "$SANDBOX/no-args.log"; then fail "no-argument invocation: missing log line for group 2 (supporting-crates)"; return; fi
  if ! grep -Fq "==> test:unit 3/7: harness-agents (bridge-runtime feature)" "$SANDBOX/no-args.log"; then fail "no-argument invocation: missing log line for group 3 (agents)"; return; fi
  if ! grep -Fq "==> test:unit 4/7: harness-task-board (daemon-runtime feature)" "$SANDBOX/no-args.log"; then fail "no-argument invocation: missing log line for group 4 (task-board)"; return; fi
  if ! grep -Fq "==> test:unit 5/7: Linux systemd crate" "$SANDBOX/no-args.log"; then fail "no-argument invocation: missing log line for group 5 (systemd)"; return; fi
  if ! grep -Fq "==> test:unit 6/7: harness-daemon (own lib)" "$SANDBOX/no-args.log"; then fail "no-argument invocation: missing log line for group 6 (daemon)"; return; fi
  if ! grep -Fq "==> test:unit 7/7: harness-daemon-bin (binary unit and integration tests)" "$SANDBOX/no-args.log"; then fail "no-argument invocation: missing log line for group 7 (daemon-bin)"; return; fi
  pass "no-argument invocation exercises and identifies all seven groups"
}

scenario_forwards_simple_filter_to_every_group() {
  reset_calls
  if ! run_task -- -E 'test(=path::to::test)' >"$SANDBOX/simple-filter.log" 2>&1; then
    fail "filtered test:unit run failed: $(<"$SANDBOX/simple-filter.log")"
    return
  fi
  if ! assert_call_count 7; then fail "filter: wrong call count"; return; fi
  if ! assert_call_matches 1 nextest run --config-file .config/nextest.toml --user-config-file none -p harness --lib --features full-runtime -E 'test(=path::to::test)'; then fail "filter: call-1 mismatch: actual=$(<"$calls_dir/call-1")"; return; fi
  if ! assert_call_matches 2 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-acme-dns -p harness-command -p harness-daemon-acp-probe -p harness-daemon-cli -p harness-daemon-client -p harness-daemon-discovery -p harness-daemon-launchd -p harness-daemon-provider-credentials -p harness-daemon-remote-cli -p harness-daemon-root -p harness-daemon-snapshot -p harness-daemon-state -p harness-daemon-watch -p harness-db-schema -p harness-feature-flags -p harness-hooks -p harness-infra -p harness-kernel -p harness-mcp -p harness-observe -p harness-panel -p harness-policy-graph-store -p harness-protocol -p harness-remote-trust -p harness-reviews -p harness-run -p harness-sybra -p harness-systemd-protocol -p harness-task-board -p harness-task-board-codex-requests -p harness-task-board-provider-sync -p harness-task-board-remote-viewer -p harness-telemetry -p harness-testkit -p harness-timeline -p harness-voice -p harness-workspace -E 'test(=path::to::test)'; then fail "filter: call-2 mismatch"; return; fi
  if ! assert_call_matches 3 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-agents --lib --features bridge-runtime -E 'test(=path::to::test)'; then fail "filter: call-3 mismatch: actual=$(<"$calls_dir/call-3")"; return; fi
  if ! assert_call_matches 4 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-task-board --lib --features daemon-runtime -E 'test(=path::to::test)'; then fail "filter: call-4 mismatch: actual=$(<"$calls_dir/call-4")"; return; fi
  if ! assert_call_matches 5 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-systemd -E 'test(=path::to::test)'; then fail "filter: call-5 mismatch: actual=$(<"$calls_dir/call-5")"; return; fi
  if ! assert_call_matches 6 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon --lib -E 'test(=path::to::test)'; then fail "filter: call-6 mismatch: actual=$(<"$calls_dir/call-6")"; return; fi
  if ! assert_call_matches 7 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon-bin -E 'test(=path::to::test)'; then fail "filter: call-7 mismatch: actual=$(<"$calls_dir/call-7")"; return; fi
  pass "a simple nextest filter reaches every package group, including harness-systemd and the harness-daemon bin"
}

scenario_preserves_multiword_single_token_filter() {
  reset_calls
  local filter='test(~foo::bar) and not test(~baz)'
  if ! run_task -- -E "$filter" >"$SANDBOX/multiword-filter.log" 2>&1; then
    fail "multi-word filter test:unit run failed: $(<"$SANDBOX/multiword-filter.log")"
    return
  fi
  if ! assert_call_count 7; then fail "multiword filter: wrong call count"; return; fi
  if ! assert_call_matches 1 nextest run --config-file .config/nextest.toml --user-config-file none -p harness --lib --features full-runtime -E "$filter"; then fail "multiword filter: call-1 mismatch: actual=$(<"$calls_dir/call-1")"; return; fi
  if ! assert_call_matches 2 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-acme-dns -p harness-command -p harness-daemon-acp-probe -p harness-daemon-cli -p harness-daemon-client -p harness-daemon-discovery -p harness-daemon-launchd -p harness-daemon-provider-credentials -p harness-daemon-remote-cli -p harness-daemon-root -p harness-daemon-snapshot -p harness-daemon-state -p harness-daemon-watch -p harness-db-schema -p harness-feature-flags -p harness-hooks -p harness-infra -p harness-kernel -p harness-mcp -p harness-observe -p harness-panel -p harness-policy-graph-store -p harness-protocol -p harness-remote-trust -p harness-reviews -p harness-run -p harness-sybra -p harness-systemd-protocol -p harness-task-board -p harness-task-board-codex-requests -p harness-task-board-provider-sync -p harness-task-board-remote-viewer -p harness-telemetry -p harness-testkit -p harness-timeline -p harness-voice -p harness-workspace -E "$filter"; then fail "multiword filter: call-2 mismatch"; return; fi
  if ! assert_call_matches 3 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-agents --lib --features bridge-runtime -E "$filter"; then fail "multiword filter: call-3 mismatch: actual=$(<"$calls_dir/call-3")"; return; fi
  if ! assert_call_matches 4 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-task-board --lib --features daemon-runtime -E "$filter"; then fail "multiword filter: call-4 mismatch: actual=$(<"$calls_dir/call-4")"; return; fi
  if ! assert_call_matches 5 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-systemd -E "$filter"; then fail "multiword filter: call-5 mismatch: actual=$(<"$calls_dir/call-5")"; return; fi
  if ! assert_call_matches 6 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon --lib -E "$filter"; then fail "multiword filter: call-6 mismatch: actual=$(<"$calls_dir/call-6")"; return; fi
  if ! assert_call_matches 7 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon-bin -E "$filter"; then fail "multiword filter: call-7 mismatch: actual=$(<"$calls_dir/call-7")"; return; fi
  pass "a filter containing spaces survives as a single token in every group"
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
    fail "shell metacharacter payload executed instead of being forwarded literally"; return
  fi
  if ! assert_call_count 7; then fail "injection: wrong call count"; return; fi
  if ! assert_call_matches 1 nextest run --config-file .config/nextest.toml --user-config-file none -p harness --lib --features full-runtime "$payload"; then fail "injection: call-1 mismatch: actual=$(<"$calls_dir/call-1")"; return; fi
  if ! assert_call_matches 2 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-acme-dns -p harness-command -p harness-daemon-acp-probe -p harness-daemon-cli -p harness-daemon-client -p harness-daemon-discovery -p harness-daemon-launchd -p harness-daemon-provider-credentials -p harness-daemon-remote-cli -p harness-daemon-root -p harness-daemon-snapshot -p harness-daemon-state -p harness-daemon-watch -p harness-db-schema -p harness-feature-flags -p harness-hooks -p harness-infra -p harness-kernel -p harness-mcp -p harness-observe -p harness-panel -p harness-policy-graph-store -p harness-protocol -p harness-remote-trust -p harness-reviews -p harness-run -p harness-sybra -p harness-systemd-protocol -p harness-task-board -p harness-task-board-codex-requests -p harness-task-board-provider-sync -p harness-task-board-remote-viewer -p harness-telemetry -p harness-testkit -p harness-timeline -p harness-voice -p harness-workspace "$payload"; then fail "injection: call-2 mismatch"; return; fi
  if ! assert_call_matches 3 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-agents --lib --features bridge-runtime "$payload"; then fail "injection: call-3 mismatch: actual=$(<"$calls_dir/call-3")"; return; fi
  if ! assert_call_matches 4 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-task-board --lib --features daemon-runtime "$payload"; then fail "injection: call-4 mismatch: actual=$(<"$calls_dir/call-4")"; return; fi
  if ! assert_call_matches 5 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-systemd "$payload"; then fail "injection: call-5 mismatch: actual=$(<"$calls_dir/call-5")"; return; fi
  if ! assert_call_matches 6 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon --lib "$payload"; then fail "injection: call-6 mismatch: actual=$(<"$calls_dir/call-6")"; return; fi
  if ! assert_call_matches 7 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon-bin "$payload"; then fail "injection: call-7 mismatch: actual=$(<"$calls_dir/call-7")"; return; fi
  pass "a shell metacharacter payload is forwarded as an inert literal argument"
}

scenario_focused_harness_task_runs_one_native_process() {
  reset_calls
  local test_name="daemon::storage::tests::dispatch_retry_budget"
  if ! run_harness_task -- "$test_name" -- --exact >"$SANDBOX/focused.log" 2>&1; then
    fail "focused Harness unit-test run failed: $(<"$SANDBOX/focused.log")"
    return
  fi
  if assert_call_count 1 \
    && assert_call_matches 1 \
      test -p harness --lib --features full-runtime "$test_name" -- --exact; then
    pass "focused Harness task runs one native libtest process with exact filtering"
  else
    fail "focused Harness task invoked unrelated packages or changed filter boundaries: $(calls_snapshot)"
  fi
}

# --- New scenarios for HARNESS_SKIP_UNIT_GROUPS / HARNESS_ONLY_UNIT_GROUP ---

scenario_only_group_runs_just_that_group() {
  reset_calls
  if ! (cd "$SANDBOX" && HARNESS_ONLY_UNIT_GROUP=daemon mise run test:unit >"$SANDBOX/only-group.log" 2>&1); then
    fail "HARNESS_ONLY_UNIT_GROUP=daemon run failed: $(<"$SANDBOX/only-group.log")"
    return
  fi
  if assert_call_count 1 \
    && assert_call_matches 1 \
      nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon --lib \
    && grep -Fq "==> test:unit 6/7: harness-daemon (own lib)" "$SANDBOX/only-group.log" \
    && grep -Fq "(skipped)" "$SANDBOX/only-group.log" \
    && ! grep -q "unknown group" "$SANDBOX/only-group.log"; then
    pass "HARNESS_ONLY_UNIT_GROUP=daemon runs only group 6 and skips the rest"
  else
    fail "HARNESS_ONLY_UNIT_GROUP=daemon did not isolate group 6: calls=$(calls_snapshot) log=$(<"$SANDBOX/only-group.log")"
  fi
}

scenario_skip_groups_skips_only_those() {
  reset_calls
  if ! (cd "$SANDBOX" && HARNESS_SKIP_UNIT_GROUPS=agents,systemd mise run test:unit >"$SANDBOX/skip-groups.log" 2>&1); then
    fail "HARNESS_SKIP_UNIT_GROUPS=agents,systemd run failed: $(<"$SANDBOX/skip-groups.log")"
    return
  fi
  if assert_call_count 5 \
    && assert_call_matches 1 nextest run --config-file .config/nextest.toml --user-config-file none -p harness --lib --features full-runtime \
    && assert_call_matches 2 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-acme-dns -p harness-command -p harness-daemon-acp-probe -p harness-daemon-cli -p harness-daemon-client -p harness-daemon-discovery -p harness-daemon-launchd -p harness-daemon-provider-credentials -p harness-daemon-remote-cli -p harness-daemon-root -p harness-daemon-snapshot -p harness-daemon-state -p harness-daemon-watch -p harness-db-schema -p harness-feature-flags -p harness-hooks -p harness-infra -p harness-kernel -p harness-mcp -p harness-observe -p harness-panel -p harness-policy-graph-store -p harness-protocol -p harness-remote-trust -p harness-reviews -p harness-run -p harness-sybra -p harness-systemd-protocol -p harness-task-board -p harness-task-board-codex-requests -p harness-task-board-provider-sync -p harness-task-board-remote-viewer -p harness-telemetry -p harness-testkit -p harness-timeline -p harness-voice -p harness-workspace \
    && assert_call_matches 3 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-task-board --lib --features daemon-runtime \
    && assert_call_matches 4 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon --lib \
    && assert_call_matches 5 nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon-bin \
    && grep -Fq "==> test:unit 3/7: harness-agents (bridge-runtime feature) (skipped)" "$SANDBOX/skip-groups.log" \
    && grep -Fq "==> test:unit 5/7: Linux systemd crate (skipped)" "$SANDBOX/skip-groups.log" \
    && ! grep -q "unknown group" "$SANDBOX/skip-groups.log"; then
    pass "HARNESS_SKIP_UNIT_GROUPS skips only the two named groups"
  else
    fail "HARNESS_SKIP_UNIT_GROUPS=agents,systemd did not skip correctly: calls=$(calls_snapshot) log=$(<"$SANDBOX/skip-groups.log")"
  fi
}

scenario_skip_groups_trims_whitespace() {
  reset_calls
  if ! (cd "$SANDBOX" && HARNESS_SKIP_UNIT_GROUPS="systemd, agents" mise run test:unit >"$SANDBOX/skip-whitespace.log" 2>&1); then
    fail "whitespace skip run failed: $(<"$SANDBOX/skip-whitespace.log")"
    return
  fi
  if grep -Fq "==> test:unit 3/7: harness-agents (bridge-runtime feature) (skipped)" "$SANDBOX/skip-whitespace.log" \
    && grep -Fq "==> test:unit 5/7: Linux systemd crate (skipped)" "$SANDBOX/skip-whitespace.log" \
    && ! grep -q "unknown group" "$SANDBOX/skip-whitespace.log"; then
    pass "HARNESS_SKIP_UNIT_GROUPS trims whitespace around group names"
  else
    fail "whitespace trim did not skip correctly: log=$(<"$SANDBOX/skip-whitespace.log")"
  fi
}

scenario_only_group_unknown_fails() {
  if (cd "$SANDBOX" && HARNESS_ONLY_UNIT_GROUP=nonexistent mise run test:unit >"$SANDBOX/only-unknown.log" 2>&1); then
    fail "HARNESS_ONLY_UNIT_GROUP=nonexistent should have failed but exited 0"
    return
  fi
  if grep -q 'unknown group name in HARNESS_ONLY_UNIT_GROUP' "$SANDBOX/only-unknown.log"; then
    pass "HARNESS_ONLY_UNIT_GROUP with an unknown name fails fast with an error"
  else
    fail "HARNESS_ONLY_UNIT_GROUP=nonexistent did not produce the expected error: $(<"$SANDBOX/only-unknown.log")"
  fi
}

scenario_skip_groups_unknown_fails() {
  if (cd "$SANDBOX" && HARNESS_SKIP_UNIT_GROUPS=nonexistent mise run test:unit >"$SANDBOX/skip-unknown.log" 2>&1); then
    fail "HARNESS_SKIP_UNIT_GROUPS=nonexistent should have failed but exited 0"
    return
  fi
  if grep -q 'unknown group name in HARNESS_SKIP_UNIT_GROUPS' "$SANDBOX/skip-unknown.log"; then
    pass "HARNESS_SKIP_UNIT_GROUPS with an unknown name fails fast with an error"
  else
    fail "HARNESS_SKIP_UNIT_GROUPS=nonexistent did not produce the expected error: $(<"$SANDBOX/skip-unknown.log")"
  fi
}

scenario_per_group_mise_task_runs_one_group() {
  reset_calls
  if ! run_group_task daemon >"$SANDBOX/group-task.log" 2>&1; then
    fail "test:unit:daemon run failed: $(<"$SANDBOX/group-task.log")"
    return
  fi
  if assert_call_count 1 \
    && assert_call_matches 1 \
      nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon --lib \
    && grep -Fq "==> test:unit 6/7: harness-daemon (own lib)" "$SANDBOX/group-task.log" \
    && grep -Fq "(skipped)" "$SANDBOX/group-task.log"; then
    pass "per-group mise task test:unit:daemon runs only group 6"
  else
    fail "per-group mise task test:unit:daemon did not isolate group 6: $(calls_snapshot)"
  fi
}

scenario_only_group_precedence_over_skip() {
  reset_calls
  if ! (cd "$SANDBOX" && HARNESS_ONLY_UNIT_GROUP=daemon HARNESS_SKIP_UNIT_GROUPS=daemon mise run test:unit >"$SANDBOX/only-precedence.log" 2>&1); then
    fail "HARNESS_ONLY_UNIT_GROUP with overlapping skip failed: $(<"$SANDBOX/only-precedence.log")"
    return
  fi
  if assert_call_count 1 \
    && assert_call_matches 1 \
      nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon --lib; then
    pass "HARNESS_ONLY_UNIT_GROUP takes precedence over HARNESS_SKIP_UNIT_GROUPS"
  else
    fail "HARNESS_ONLY_UNIT_GROUP did not take precedence: $(calls_snapshot)"
  fi
}

scenario_only_group_rejects_comma_separated() {
  if (cd "$SANDBOX" && HARNESS_ONLY_UNIT_GROUP="daemon,systemd" mise run test:unit >"$SANDBOX/only-comma.log" 2>&1); then
    fail "HARNESS_ONLY_UNIT_GROUP with commas should have failed but exited 0"
    return
  fi
  if grep -q 'must be a single group name' "$SANDBOX/only-comma.log"; then
    pass "HARNESS_ONLY_UNIT_GROUP rejects comma-separated values"
  else
    fail "HARNESS_ONLY_UNIT_GROUP=daemon,systemd did not produce the expected error: $(<"$SANDBOX/only-comma.log")"
  fi
}

scenario_no_arguments_preserves_all_groups
scenario_forwards_simple_filter_to_every_group
scenario_preserves_multiword_single_token_filter
scenario_rejects_shell_injection_attempt
scenario_focused_harness_task_runs_one_native_process
scenario_only_group_runs_just_that_group
scenario_skip_groups_skips_only_those
scenario_skip_groups_trims_whitespace
scenario_only_group_unknown_fails
scenario_skip_groups_unknown_fails
scenario_per_group_mise_task_runs_one_group
scenario_only_group_precedence_over_skip
scenario_only_group_rejects_comma_separated

printf 'run-unit-tests tests: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT" >&2
(( FAIL_COUNT == 0 ))
