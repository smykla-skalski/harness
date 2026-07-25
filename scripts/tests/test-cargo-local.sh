#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$ROOT/scripts/lib/common-repo-root.sh"
COMMON_REPO_ROOT="$(resolve_common_repo_root "$ROOT")"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cargo-local-test.XXXXXX")"
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
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

assert_contains() {
  local needle="$1" haystack="$2"
  grep -Fq -- "$needle" <<<"$haystack"
}

assert_line() {
  local line="$1" haystack="$2"
  grep -Fxq -- "$line" <<<"$haystack"
}

write_fake_sccache() {
  local path="$1" version="$2"
  cat >"$path" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
  printf 'sccache $version\n'
  exit 0
fi
printf 'unexpected fake sccache invocation\n' >&2
exit 91
EOF
  chmod +x "$path"
}

print_cargo_env() {
  local fake_bin="$1" sccache_bin="$2" tmpdir="$3"
  (
    unset SCCACHE_SERVER_UDS SCCACHE_SERVER_PORT SCCACHE_NO_DAEMON
    unset SCCACHE_BASEDIRS SCCACHE_IDLE_TIMEOUT SCCACHE_CACHE_SIZE SCCACHE_VERSION
    unset HARNESS_SCCACHE_TMPDIR
    PATH="$fake_bin:$PATH" \
      SCCACHE_BIN="$sccache_bin" \
      RUSTC_WRAPPER='' \
      TMPDIR="$tmpdir/" \
      CODEX_SESSION_ID="cargo-local-test-$$" \
      HARNESS_CARGO_SKIP_LEASE=1 \
      HARNESS_CARGO_ACTIVE_BUILD_COUNT=1 \
      "$ROOT/scripts/cargo-local.sh" --print-env
  )
}

print_cargo_env_without_tmpdir() {
  local fake_bin="$1" sccache_bin="$2" session="$3"
  (
    unset SCCACHE_SERVER_UDS SCCACHE_SERVER_PORT SCCACHE_NO_DAEMON
    unset SCCACHE_BASEDIRS SCCACHE_IDLE_TIMEOUT SCCACHE_CACHE_SIZE SCCACHE_VERSION
    unset HARNESS_SCCACHE_TMPDIR TMPDIR
    unset CODEX_THREAD_ID CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
    unset GEMINI_SESSION_ID COPILOT_SESSION_ID OPENCODE_SESSION_ID
    PATH="$fake_bin:$PATH" \
      SCCACHE_BIN="$sccache_bin" \
      RUSTC_WRAPPER='' \
      CODEX_SESSION_ID="$session" \
      HARNESS_CARGO_SKIP_LEASE=1 \
      HARNESS_CARGO_ACTIVE_BUILD_COUNT=1 \
      "$ROOT/scripts/cargo-local.sh" --print-env
  )
}

print_tmpdir_env() {
  local session_id="$1" configured_tmpdir="${2:-}"
  (
    unset SCCACHE_SERVER_UDS SCCACHE_SERVER_PORT SCCACHE_NO_DAEMON
    unset SCCACHE_BASEDIRS SCCACHE_IDLE_TIMEOUT SCCACHE_CACHE_SIZE SCCACHE_VERSION
    unset HARNESS_SCCACHE_TMPDIR
    unset CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
    unset GEMINI_SESSION_ID COPILOT_SESSION_ID OPENCODE_SESSION_ID
    if [[ -n "$configured_tmpdir" ]]; then
      export TMPDIR="$configured_tmpdir"
    else
      unset TMPDIR
    fi
    SCCACHE_BIN="$SANDBOX/missing-sccache" \
      RUSTC_WRAPPER='' \
      CODEX_SESSION_ID="$session_id" \
      HARNESS_CARGO_SKIP_LEASE=1 \
      HARNESS_CARGO_ACTIVE_BUILD_COUNT=1 \
      "$ROOT/scripts/cargo-local.sh" --print-env
  )
}

scenario_missing_tmpdir_uses_short_external_fallback() {
  local first second other fallback other_fallback test_threads

  first="$(print_tmpdir_env "cargo-local-tmp-a-$$")"
  second="$(print_tmpdir_env "cargo-local-tmp-a-$$")"
  other="$(print_tmpdir_env "cargo-local-tmp-b-$$")"
  fallback="$(awk -F= '$1 == "TMPDIR" { print substr($0, index($0, "=") + 1) }' <<<"$first")"
  other_fallback="$(
    awk -F= '$1 == "TMPDIR" { print substr($0, index($0, "=") + 1) }' <<<"$other"
  )"
  test_threads="$(
    awk -F= '$1 == "NEXTEST_TEST_THREADS" { print substr($0, index($0, "=") + 1) }' <<<"$first"
  )"

  if [[ "$fallback" == /tmp/harness-cargo-*/ ]] \
    && (( ${#fallback} < 64 )) \
    && [[ ! -L "${fallback%/}" ]] \
    && [[ -O "${fallback%/}" ]] \
    && assert_line "TMPDIR=$fallback" "$second" \
    && [[ "$fallback" != "$other_fallback" ]] \
    && [[ -d "${fallback%/}" ]] \
    && [[ "$fallback" != "$ROOT/"* ]] \
    && [[ "$fallback" != "$COMMON_REPO_ROOT/"* ]] \
    && [[ "$test_threads" =~ ^[0-9]+$ ]] \
    && (( test_threads >= 2 )); then
    pass "missing TMPDIR uses a stable short external repo/session fallback"
  else
    fail "missing TMPDIR fallback was not short, external, and session-scoped: $first"
  fi

  rm -rf "${fallback%/}" "${other_fallback%/}"
}

scenario_concurrent_tmpdir_creation_is_idempotent() {
  local barrier="$SANDBOX/mkdir-barrier"
  local fake_bin="$SANDBOX/mkdir-bin"
  local first="$SANDBOX/concurrent-first.out"
  local second="$SANDBOX/concurrent-second.out"
  local real_mkdir session_id first_pid second_pid first_status second_status fallback
  real_mkdir="$(command -v mkdir)"
  session_id="cargo-local-concurrent-tmp-$$"
  mkdir -p "$barrier" "$fake_bin"
  cat >"$fake_bin/mkdir" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${!#}"
if [[ "$target" == /tmp/harness-cargo-* ]]; then
  : >"$HARNESS_TEST_MKDIR_BARRIER/$$"
  for _ in {1..200}; do
    count=0
    for marker in "$HARNESS_TEST_MKDIR_BARRIER"/*; do
      [[ -e "$marker" ]] && count=$((count + 1))
    done
    (( count >= 2 )) && break
    sleep 0.01
  done
fi
exec "$HARNESS_TEST_REAL_MKDIR" "$@"
EOF
  chmod +x "$fake_bin/mkdir"

  PATH="$fake_bin:$PATH" HARNESS_TEST_MKDIR_BARRIER="$barrier" \
    HARNESS_TEST_REAL_MKDIR="$real_mkdir" print_tmpdir_env "$session_id" >"$first" 2>&1 &
  first_pid=$!
  PATH="$fake_bin:$PATH" HARNESS_TEST_MKDIR_BARRIER="$barrier" \
    HARNESS_TEST_REAL_MKDIR="$real_mkdir" print_tmpdir_env "$session_id" >"$second" 2>&1 &
  second_pid=$!

  set +e
  wait "$first_pid"
  first_status=$?
  wait "$second_pid"
  second_status=$?
  set -e

  fallback="$(
    awk -F= '$1 == "TMPDIR" { print substr($0, index($0, "=") + 1) }' "$first"
  )"
  if (( first_status == 0 && second_status == 0 )) \
    && [[ -n "$fallback" ]] \
    && grep -Fxq -- "TMPDIR=$fallback" "$second"; then
    pass "concurrent same-session TMPDIR creation is idempotent"
  else
    fail "concurrent TMPDIR creation failed: first=$(<"$first") second=$(<"$second")"
  fi
  rm -rf "${fallback%/}"
}

scenario_unusable_tmpdir_uses_short_external_fallback() {
  local unusable="$SANDBOX/not-a-directory" output fallback
  : >"$unusable"

  output="$(print_tmpdir_env "cargo-local-unusable-tmp-$$" "$unusable")"
  fallback="$(
    awk -F= '$1 == "TMPDIR" { print substr($0, index($0, "=") + 1) }' <<<"$output"
  )"

  if [[ "$fallback" == /tmp/harness-cargo-*/ ]] \
    && (( ${#fallback} < 64 )) \
    && [[ -d "${fallback%/}" ]]; then
    pass "unusable TMPDIR uses a short external fallback"
  else
    fail "unusable TMPDIR did not use the short external fallback: $output"
  fi

  rm -rf "${fallback%/}"
}

scenario_usable_tmpdir_is_preserved() {
  local explicit="$SANDBOX/explicit-tmp" output
  mkdir -p "$explicit"

  output="$(print_tmpdir_env "cargo-local-explicit-tmp-$$" "$explicit/")"
  if assert_line "TMPDIR=$explicit/" "$output"; then
    pass "usable explicit TMPDIR is preserved"
  else
    fail "usable explicit TMPDIR was replaced: $output"
  fi
}

scenario_agent_build_jobs_leave_room_for_later_arrivals() {
  local fake_bin="$SANDBOX/cpu-bin"
  local agent_output local_output
  local cpu_count=24 expected_agent_jobs
  # An agent that starts alone still has to leave room for agents that join
  # later, because the lease count it saw can only shrink its share, never
  # grow it back.
  expected_agent_jobs=$(((cpu_count + 3) / 4))
  mkdir -p "$fake_bin"
  cat >"$fake_bin/getconf" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "_NPROCESSORS_ONLN" ]]; then
  printf '$cpu_count\n'
  exit 0
fi
exit 1
EOF
  chmod +x "$fake_bin/getconf"

  agent_output="$(
    PATH="$fake_bin:$PATH" \
      CARGO_BUILD_JOBS='' \
      HARNESS_CARGO_JOBS='' \
      print_tmpdir_env "cargo-local-all-cpus-agent-$$"
  )"
  local_output="$(
    unset CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
    unset GEMINI_SESSION_ID COPILOT_SESSION_ID OPENCODE_SESSION_ID
    PATH="$fake_bin:$PATH" \
      CARGO_BUILD_JOBS='' \
      HARNESS_CARGO_JOBS='' \
      HARNESS_CARGO_SKIP_LEASE=1 \
      HARNESS_CARGO_ACTIVE_BUILD_COUNT=1 \
      SCCACHE_BIN="$SANDBOX/missing-sccache" \
      RUSTC_WRAPPER='' \
      "$ROOT/scripts/cargo-local.sh" --print-env
  )"

  if assert_line "CARGO_BUILD_JOBS=$expected_agent_jobs" "$agent_output" \
    && assert_line "CARGO_BUILD_JOBS=$cpu_count" "$local_output"; then
    pass "local builds take every CPU and agent builds keep a bounded share"
  else
    fail "unexpected build job split: agent=$agent_output local=$local_output"
  fi
}

scenario_target_dir_is_shared_across_sessions() {
  local first second first_dir second_dir first_tmp second_tmp

  first="$(print_tmpdir_env "cargo-local-target-a-$$")"
  second="$(print_tmpdir_env "cargo-local-target-b-$$")"
  first_dir="$(
    awk -F= '$1 == "CARGO_TARGET_DIR" { print substr($0, index($0, "=") + 1) }' <<<"$first"
  )"
  second_dir="$(
    awk -F= '$1 == "CARGO_TARGET_DIR" { print substr($0, index($0, "=") + 1) }' <<<"$second"
  )"
  first_tmp="$(awk -F= '$1 == "TMPDIR" { print substr($0, index($0, "=") + 1) }' <<<"$first")"
  second_tmp="$(awk -F= '$1 == "TMPDIR" { print substr($0, index($0, "=") + 1) }' <<<"$second")"

  if [[ -n "$first_dir" ]] \
    && [[ "$first_dir" == "$second_dir" ]] \
    && [[ "$first_dir" != *"cargo-local-target-a-$$"* ]] \
    && [[ "$first_tmp" != "$second_tmp" ]]; then
    pass "sessions in one checkout share a build cache and keep separate TMPDIRs"
  else
    fail "build cache is still session-scoped: a=$first_dir b=$second_dir"
  fi

  rm -rf "${first_tmp%/}" "${second_tmp%/}"
}

scenario_sccache_socket_survives_session_scoped_tmpdir() {
  local fake_bin="$SANDBOX/socket-share-bin"
  local first second first_sock second_sock first_tmp second_tmp
  mkdir -p "$fake_bin"
  write_fake_sccache "$fake_bin/sccache" "0.16.0"

  first="$(print_cargo_env_without_tmpdir "$fake_bin" "$fake_bin/sccache" "sock-a-$$")"
  second="$(print_cargo_env_without_tmpdir "$fake_bin" "$fake_bin/sccache" "sock-b-$$")"
  first_sock="$(
    awk -F= '$1 == "SCCACHE_SERVER_UDS" { print substr($0, index($0, "=") + 1) }' <<<"$first"
  )"
  second_sock="$(
    awk -F= '$1 == "SCCACHE_SERVER_UDS" { print substr($0, index($0, "=") + 1) }' <<<"$second"
  )"
  first_tmp="$(awk -F= '$1 == "TMPDIR" { print substr($0, index($0, "=") + 1) }' <<<"$first")"
  second_tmp="$(awk -F= '$1 == "TMPDIR" { print substr($0, index($0, "=") + 1) }' <<<"$second")"

  # Distinct session TMPDIRs must not drag the socket along with them, or each
  # session quietly gets its own sccache server over the same on-disk cache.
  if [[ -n "$first_sock" ]] \
    && [[ "$first_tmp" != "$second_tmp" ]] \
    && [[ "$first_sock" == "$second_sock" ]]; then
    pass "one sccache socket per repo despite session-scoped TMPDIRs"
  else
    fail "sccache socket followed the session TMPDIR: a=$first_sock b=$second_sock"
  fi

  rm -rf "${first_tmp%/}" "${second_tmp%/}"
}

scenario_single_thread_nextest_override_is_rejected() {
  local output single_thread status
  single_thread="$((2 - 1))"

  set +e
  output="$(
    NEXTEST_TEST_THREADS="$single_thread" \
      print_tmpdir_env "cargo-local-serial-nextest-$$" 2>&1
  )"
  status=$?
  set -e

  if (( status == 2 )) \
    && assert_contains "NEXTEST_TEST_THREADS must be num-cpus or an integer greater than one" \
      "$output"; then
    pass "single-thread nextest override is rejected"
  else
    fail "single-thread nextest override should fail with status 2: $output"
  fi
}

scenario_noncanonical_nextest_override_is_rejected() {
  local invalid_threads="08" output status

  set +e
  output="$(
    NEXTEST_TEST_THREADS="$invalid_threads" \
      print_tmpdir_env "cargo-local-noncanonical-nextest-$$" 2>&1
  )"
  status=$?
  set -e

  if (( status == 2 )) \
    && assert_contains "NEXTEST_TEST_THREADS must be num-cpus or an integer greater than one" \
      "$output"; then
    pass "noncanonical nextest override is rejected cleanly"
  else
    fail "noncanonical nextest override should fail with status 2: $output"
  fi
}

scenario_supported_sccache_is_resolved_once() {
  local fake_bin="$SANDBOX/supported-bin"
  local tmpdir="$SANDBOX/supported-tmp"
  local output
  mkdir -p "$fake_bin" "$tmpdir"
  write_fake_sccache "$fake_bin/sccache" "0.16.0"

  output="$(print_cargo_env "$fake_bin" "$fake_bin/sccache" "$tmpdir")"
  # A sandbox under the macOS per-user TMPDIR already exceeds the socket-root
  # length limit, so the short /tmp root is a correct answer here too.
  if assert_line "SCCACHE_BIN=$fake_bin/sccache" "$output" \
    && assert_line "SCCACHE_VERSION=0.16.0" "$output" \
    && assert_line "SCCACHE_BASEDIRS=$ROOT:$COMMON_REPO_ROOT" "$output" \
    && { assert_contains "SCCACHE_SERVER_UDS=$tmpdir/harness-sccache/" "$output" \
      || assert_contains "SCCACHE_SERVER_UDS=/tmp/harness-sccache-" "$output"; } \
    && assert_line "CACHE_MODE=sccache" "$output"; then
    pass "supported sccache is resolved once"
  else
    fail "supported sccache environment was incomplete: $output"
  fi
}

scenario_old_explicit_sccache_is_disabled() {
  local fake_bin="$SANDBOX/old-bin"
  local tmpdir="$SANDBOX/old-tmp"
  local output
  mkdir -p "$fake_bin" "$tmpdir"
  write_fake_sccache "$fake_bin/sccache" "0.7.7"

  output="$(print_cargo_env "$fake_bin" "$fake_bin/sccache" "$tmpdir")"
  if assert_line "SCCACHE_BIN=" "$output" \
    && assert_line "SCCACHE_VERSION=" "$output" \
    && assert_line "SCCACHE_SERVER_UDS=" "$output" \
    && assert_line "CACHE_MODE=none" "$output"; then
    pass "old explicit sccache is disabled"
  else
    fail "old sccache should not be enabled: $output"
  fi
}

scenario_failed_lsof_preserves_unknown_sockets() {
  local fake_bin="$SANDBOX/lsof-bin"
  local tmpdir="$SANDBOX/lsof-tmp"
  local socket_dir="$tmpdir/harness-sccache"
  local unknown_socket="$socket_dir/unknown.sock"
  mkdir -p "$fake_bin" "$socket_dir"
  write_fake_sccache "$fake_bin/sccache" "0.16.0"
  cat >"$fake_bin/lsof" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$fake_bin/lsof"
  : >"$unknown_socket"

  print_cargo_env "$fake_bin" "$fake_bin/sccache" "$tmpdir" >/dev/null
  if [[ -e "$unknown_socket" ]]; then
    pass "failed lsof preserves sockets with unknown ownership"
  else
    fail "socket was deleted after lsof failed"
  fi
}

scenario_cache_wrapper_shortens_long_tmpdir() {
  local fake_bin="$SANDBOX/wrapper-bin"
  local long_tmp
  local observed_tmp="$SANDBOX/observed-tmp"
  long_tmp="$SANDBOX/$(printf 'long-path-%.0s' {1..10})"
  mkdir -p "$fake_bin" "$long_tmp"
  cat >"$fake_bin/sccache" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
  printf 'wrapper repeated the resolved version probe\n' >&2
  exit 92
fi
printf '%s\n' "\${TMPDIR:-}" >"$observed_tmp"
exit 0
EOF
  chmod +x "$fake_bin/sccache"

  TMPDIR="$long_tmp/" SCCACHE_BIN="$fake_bin/sccache" SCCACHE_VERSION="0.16.0" \
    "$ROOT/scripts/rustc-cache-wrapper.sh" fake-rustc -vV
  if [[ "$(<"$observed_tmp")" == "/tmp/" ]]; then
    pass "cache wrapper shortens long TMPDIR paths"
  else
    fail "cache wrapper retained an overlong TMPDIR: $(<"$observed_tmp")"
  fi
}

scenario_missing_tmpdir_uses_short_external_fallback
scenario_concurrent_tmpdir_creation_is_idempotent
scenario_unusable_tmpdir_uses_short_external_fallback
scenario_usable_tmpdir_is_preserved
scenario_agent_build_jobs_leave_room_for_later_arrivals
scenario_target_dir_is_shared_across_sessions
scenario_sccache_socket_survives_session_scoped_tmpdir
scenario_single_thread_nextest_override_is_rejected
scenario_noncanonical_nextest_override_is_rejected
scenario_supported_sccache_is_resolved_once
scenario_old_explicit_sccache_is_disabled
scenario_failed_lsof_preserves_unknown_sockets
scenario_cache_wrapper_shortens_long_tmpdir

printf 'cargo-local tests: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT" >&2
(( FAIL_COUNT == 0 ))
