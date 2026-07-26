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

# GNU and BSD stat disagree on the format flag, and GNU's -f means something
# else entirely and still exits 0, so validate the shape before trusting it.
dir_mode() {
  local path="$1" mode
  mode="$(stat -c '%a' "$path" 2>/dev/null || true)"
  if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]]; then
    mode="$(stat -f '%Lp' "$path" 2>/dev/null || true)"
  fi
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  printf '%s\n' "$mode"
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
    unset CARGO_TARGET_DIR HARNESS_CARGO_TARGET_DIR
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

# Read the reserve from the script so the curve assertions track the source
# rather than a copy of it. A missing or absurd value has to fail loudly: left
# empty it would silently take every scenario that depends on it out of the run.
agent_build_share() {
  local share
  share="$(awk -F= '/^AGENT_BUILD_SHARE=/ { print $2; exit }' "$ROOT/scripts/cargo-local.sh")"
  if [[ ! "$share" =~ ^[0-9]+$ ]] || (( share < 2 )) || (( share > 8 )); then
    printf 'AGENT_BUILD_SHARE must be an integer in 2..8 (got %s)\n' "${share:-unset}" >&2
    return 1
  fi
  printf '%s\n' "$share"
}

# Key the pool by an arbitrary string so a scenario never shares a supervisor
# with the developer's real repository pool.
# The pool is only offered to a make that can parse a fifo endpoint, so a
# scenario meaning to exercise pool mode has to pin one. Without it these tests
# assert on the runner's make version - green on a macOS box with 4.4, falling
# back to the reserve on Ubuntu 24.04, and never the code they were written for.
fifo_capable_make_path() {
  local shim="$SANDBOX/make-shim"
  mkdir -p "$shim"
  printf '#!/usr/bin/env bash\nprintf "GNU Make 4.4.1\\n"\n' >"$shim/make"
  chmod +x "$shim/make"
  printf '%s\n' "$shim"
}

print_cargo_env_with_pool_key() {
  local pool_key="$1"
  shift
  # Hand over an explicit TMPDIR. Without one these runs create the shared
  # in-repo TMPDIR base, and the scenarios below need to own that path.
  local scratch="$SANDBOX/pool-tmp"
  mkdir -p "$scratch"
  # Whether the pool may be used at all now depends on the host's make, so
  # without this every pool assertion below would test the runner rather than
  # the code - passing on a macOS box with make 4.4 and falling back on Ubuntu
  # 24.04. The scenario that owns that decision sets its own make instead.
  # Passed as a per-command assignment rather than set inside the subshell, so
  # the shim reaches cargo-local.sh without shellcheck reading it as a lost edit.
  local run_path="$PATH"
  [[ -n "${HARNESS_TEST_MAKE_ON_PATH:-}" ]] || run_path="$(fifo_capable_make_path):$PATH"
  # Start the supervisor up front so the run under test only has to attach to a
  # pool that already answers. Folding daemon startup into the assertion made
  # this flaky on a loaded host, where spawning it can outrun the wait.
  local cpu budget
  cpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.logicalcpu)"
  budget=$((cpu - 1))
  (( budget < 1 )) && budget=1
  python3 "$ROOT/scripts/harness-jobserver.py" ensure \
    --repo-root "$pool_key" --budget "$budget" >/dev/null 2>&1 || true
  (
    unset SCCACHE_SERVER_UDS SCCACHE_SERVER_PORT SCCACHE_NO_DAEMON
    unset SCCACHE_BASEDIRS SCCACHE_IDLE_TIMEOUT SCCACHE_CACHE_SIZE SCCACHE_VERSION
    unset HARNESS_SCCACHE_TMPDIR
    unset CARGO_TARGET_DIR HARNESS_CARGO_TARGET_DIR
    unset CARGO_BUILD_JOBS HARNESS_CARGO_JOBS MAKEFLAGS MFLAGS CARGO_MAKEFLAGS
    TMPDIR="$scratch/" \
      PATH="$run_path" \
      RUSTC_WRAPPER='' \
      SCCACHE_BIN='' \
      CODEX_SESSION_ID="cargo-local-pool-$$" \
      HARNESS_CARGO_SKIP_LEASE=1 \
      HARNESS_CARGO_ACTIVE_BUILD_COUNT=1 \
      HARNESS_JOBSERVER_POOL_KEY="$pool_key" \
      "$@" \
      "$ROOT/scripts/cargo-local.sh" --print-env
  )
}

stop_pool_for_key() {
  local key="$1" dir pid
  dir="$(python3 - "$ROOT/scripts/harness-jobserver.py" "$key" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("js", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(mod.pool_dir(sys.argv[2]))
PY
)" || return 0
  pid="$(head -1 "$dir/lock" 2>/dev/null || true)"
  # The lock file outlives the process that wrote it, and a dead supervisor's
  # pid gets recycled - on a box also running other agents' builds, signalling
  # it blind can kill something unrelated to this suite.
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    case "$(ps -p "$pid" -o command= 2>/dev/null)" in
      *harness-jobserver.py*supervise*) kill "$pid" 2>/dev/null || true ;;
    esac
  fi
  rm -rf "$dir" 2>/dev/null || true
}

# Stand in for cargo and record, per invocation, how many tokens were sitting in
# the pool FIFO when it started.
write_token_counting_cargo() {
  local path="$1" log="$2"
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
fifo="${CARGO_MAKEFLAGS##*fifo:}"
count=0
if [[ -p "$fifo" ]]; then
  count="$(python3 - "$fifo" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_NONBLOCK)
total = 0
while True:
    try:
        chunk = os.read(fd, 4096)
    except BlockingIOError:
        break
    if not chunk:
        break
    total += len(chunk)
if total:
    os.write(fd, b"+" * total)
print(total)
PY
)"
fi
printf '%s %s\n' "$count" "$*" >> "$TOKEN_LOG"
EOF
  chmod +x "$path"
  : >"$log"
}

scenario_nextest_build_phase_keeps_the_whole_pool() {
  local key="pool-buildphase-$$"
  local fake="$SANDBOX/token-cargo"
  local log="$SANDBOX/token-log"
  local scratch="$SANDBOX/buildphase-tmp"
  mkdir -p "$fake" "$scratch"
  write_token_counting_cargo "$fake/cargo" "$log"

  local cpu budget
  cpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.logicalcpu)"
  budget=$((cpu - 1)); (( budget < 1 )) && budget=1
  python3 "$ROOT/scripts/harness-jobserver.py" ensure \
    --repo-root "$key" --budget "$budget" >/dev/null 2>&1 || true

  (
    unset CARGO_TARGET_DIR HARNESS_CARGO_TARGET_DIR MAKEFLAGS MFLAGS CARGO_MAKEFLAGS
    unset NEXTEST_TEST_THREADS HARNESS_NEXTEST_JOBS
    TMPDIR="$scratch/" \
      PATH="$(fifo_capable_make_path):$PATH" \
      TOKEN_LOG="$log" \
      SCCACHE_BIN='' RUSTC_WRAPPER='' \
      CODEX_SESSION_ID="cargo-local-buildphase-$$" \
      HARNESS_CARGO_SKIP_LEASE=1 \
      HARNESS_CARGO_ACTIVE_BUILD_COUNT=1 \
      HARNESS_JOBSERVER_POOL_KEY="$key" \
      HARNESS_CARGO_BIN="$fake/cargo" \
      "$ROOT/scripts/cargo-local.sh" nextest run --lib >/dev/null 2>&1
  )
  stop_pool_for_key "$key"

  # cargo-local probes the binary with `cargo -V` before doing anything, so
  # count only the invocations that carry the subcommand.
  local build_tokens run_tokens
  build_tokens="$(awk '/nextest/ {print $1; exit}' "$log")"
  run_tokens="$(awk '/nextest/ {n++; if (n == 2) {print $1; exit}}' "$log")"

  if [[ ! "$build_tokens" =~ ^[0-9]+$ ]] || [[ ! "$run_tokens" =~ ^[0-9]+$ ]]; then
    fail "nextest was not split into a build and a run phase: $(tr '\n' '|' <"$log")"
    return
  fi
  # The build must see the full pool. Holding the block across it starved the
  # compile that produces the very binaries the block is reserved for.
  if (( build_tokens < budget )); then
    fail "nextest build phase was starved: saw $build_tokens of $budget tokens"
    return
  fi
  if (( run_tokens != 0 )); then
    fail "nextest run phase did not hold the block: $run_tokens tokens still free"
    return
  fi
  pass "the nextest build phase keeps the whole pool, the run phase holds it"
}

scenario_build_only_flag_precedes_a_separator() {
  local key="pool-sep-$$"
  local fake="$SANDBOX/sep-cargo"
  local log="$SANDBOX/sep-log"
  local scratch="$SANDBOX/sep-tmp"
  mkdir -p "$fake" "$scratch"
  write_token_counting_cargo "$fake/cargo" "$log"

  local cpu budget
  cpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.logicalcpu)"
  budget=$((cpu - 1)); (( budget < 1 )) && budget=1
  python3 "$ROOT/scripts/harness-jobserver.py" ensure \
    --repo-root "$key" --budget "$budget" >/dev/null 2>&1 || true

  (
    unset CARGO_TARGET_DIR HARNESS_CARGO_TARGET_DIR MAKEFLAGS MFLAGS CARGO_MAKEFLAGS
    unset NEXTEST_TEST_THREADS HARNESS_NEXTEST_JOBS
    TMPDIR="$scratch/" \
      PATH="$(fifo_capable_make_path):$PATH" \
      TOKEN_LOG="$log" \
      SCCACHE_BIN='' RUSTC_WRAPPER='' \
      CODEX_SESSION_ID="cargo-local-sep-$$" \
      HARNESS_CARGO_SKIP_LEASE=1 \
      HARNESS_CARGO_ACTIVE_BUILD_COUNT=1 \
      HARNESS_JOBSERVER_POOL_KEY="$key" \
      HARNESS_CARGO_BIN="$fake/cargo" \
      "$ROOT/scripts/cargo-local.sh" nextest run --lib -- --exact >/dev/null 2>&1
  )
  stop_pool_for_key "$key"

  local build_args
  build_args="$(awk '/nextest/ {sub(/^[0-9]+ /, ""); print; exit}' "$log")"
  # Appended at the end, --no-run would sit past the caller's separator and
  # reach the test binary, so the build phase would run the suite instead.
  if [[ "$build_args" != *"--no-run -- --exact" ]]; then
    fail "--no-run did not precede the caller's separator: '$build_args'"
    return
  fi
  pass "the build-only flag precedes a caller's argument separator"
}

scenario_nextest_detection_skips_global_flag_values() {
  local key="pool-flagvalue-$$"
  local fake="$SANDBOX/flagvalue-cargo"
  local log="$SANDBOX/flagvalue-log"
  local scratch="$SANDBOX/flagvalue-tmp"
  mkdir -p "$fake" "$scratch"
  write_token_counting_cargo "$fake/cargo" "$log"

  local cpu budget
  cpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.logicalcpu)"
  budget=$((cpu - 1)); (( budget < 1 )) && budget=1
  python3 "$ROOT/scripts/harness-jobserver.py" ensure \
    --repo-root "$key" --budget "$budget" >/dev/null 2>&1 || true

  run_flagvalue() {
    (
      unset CARGO_TARGET_DIR HARNESS_CARGO_TARGET_DIR MAKEFLAGS MFLAGS CARGO_MAKEFLAGS
      unset NEXTEST_TEST_THREADS HARNESS_NEXTEST_JOBS
      TMPDIR="$scratch/" \
        PATH="$(fifo_capable_make_path):$PATH" \
        TOKEN_LOG="$log" \
        SCCACHE_BIN='' RUSTC_WRAPPER='' \
        CODEX_SESSION_ID="cargo-local-flagvalue-$$" \
        HARNESS_CARGO_SKIP_LEASE=1 \
        HARNESS_CARGO_ACTIVE_BUILD_COUNT=1 \
        HARNESS_JOBSERVER_POOL_KEY="$key" \
        HARNESS_CARGO_BIN="$fake/cargo" \
        "$ROOT/scripts/cargo-local.sh" "$@" >/dev/null 2>&1
    )
  }

  # `--color always` puts a bare word before the subcommand, and reading it as
  # the subcommand dropped the split silently.
  : >"$log"
  run_flagvalue --color always nextest run --lib
  local split_invocations; split_invocations="$(grep -c nextest "$log")"

  # Same shape without nextest, which must still not split. Count only the
  # forwarded command; cargo-local also probes the binary with a bare -V.
  : >"$log"
  run_flagvalue --color always run
  local plain_invocations; plain_invocations="$(grep -c -- '--color' "$log")"
  stop_pool_for_key "$key"

  if [[ "$split_invocations" != "2" ]]; then
    fail "a value-taking global flag broke the split ($split_invocations cargo invocations)"
    return
  fi
  if [[ "$plain_invocations" != "1" ]]; then
    fail "cargo run after a global flag should not split ($plain_invocations cargo invocations)"
    return
  fi
  pass "nextest detection skips the value of a global flag"
}

scenario_nextest_detection_handles_toolchain_and_list() {
  local key="pool-detect-$$"
  local fake="$SANDBOX/detect-cargo"
  local log="$SANDBOX/detect-log"
  local scratch="$SANDBOX/detect-tmp"
  mkdir -p "$fake" "$scratch"
  write_token_counting_cargo "$fake/cargo" "$log"

  local cpu budget
  cpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.logicalcpu)"
  budget=$((cpu - 1)); (( budget < 1 )) && budget=1
  python3 "$ROOT/scripts/harness-jobserver.py" ensure \
    --repo-root "$key" --budget "$budget" >/dev/null 2>&1 || true

  run_detect() {
    (
      unset CARGO_TARGET_DIR HARNESS_CARGO_TARGET_DIR MAKEFLAGS MFLAGS CARGO_MAKEFLAGS
      unset NEXTEST_TEST_THREADS HARNESS_NEXTEST_JOBS
      TMPDIR="$scratch/" \
        PATH="$(fifo_capable_make_path):$PATH" \
        TOKEN_LOG="$log" \
        SCCACHE_BIN='' RUSTC_WRAPPER='' \
        CODEX_SESSION_ID="cargo-local-detect-$$" \
        HARNESS_CARGO_SKIP_LEASE=1 \
        HARNESS_CARGO_ACTIVE_BUILD_COUNT=1 \
        HARNESS_JOBSERVER_POOL_KEY="$key" \
        HARNESS_CARGO_BIN="$fake/cargo" \
        "$ROOT/scripts/cargo-local.sh" "$@" >/dev/null 2>&1
    )
  }

  # A toolchain selector sits before the subcommand and is not a flag; missing
  # it silently dropped the split for `cargo +nightly nextest run`.
  : >"$log"
  run_detect +nightly nextest run --lib
  local toolchain_invocations; toolchain_invocations="$(grep -c nextest "$log")"

  # `nextest list` builds but runs nothing, so it wants no test block.
  : >"$log"
  run_detect nextest list
  local list_invocations; list_invocations="$(grep -c nextest "$log")"
  stop_pool_for_key "$key"

  if [[ "$toolchain_invocations" != "2" ]]; then
    fail "toolchain-prefixed nextest run was not split ($toolchain_invocations cargo invocations)"
    return
  fi
  if [[ "$list_invocations" != "1" ]]; then
    fail "nextest list should not be split ($list_invocations cargo invocations)"
    return
  fi
  pass "nextest detection handles a toolchain prefix and skips list"
}

scenario_jobserver_pool_takes_over_build_sizing() {
  local key="pool-sizing-$$"
  local output cpu
  output="$(print_cargo_env_with_pool_key "$key")"
  cpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.logicalcpu)"
  stop_pool_for_key "$key"

  if ! assert_line "JOBSERVER=pool" "$output"; then
    fail "jobserver pool was not used: $(grep '^JOBSERVER=' <<<"$output")"
    return
  fi
  if ! assert_contains "--jobserver-auth=fifo:" "$output"; then
    fail "CARGO_MAKEFLAGS carried no endpoint: $(grep '^CARGO_MAKEFLAGS=' <<<"$output")"
    return
  fi
  # The pool caps concurrency now, so the per-process reserve must step aside
  # and let cargo ask for the whole machine.
  if ! assert_line "CARGO_BUILD_JOBS=$cpu" "$output"; then
    fail "pool did not widen build jobs to $cpu: $(grep '^CARGO_BUILD_JOBS=' <<<"$output")"
    return
  fi
  pass "an available pool widens build jobs and exports a jobserver"
}

scenario_old_make_keeps_the_pool_at_arms_length() {
  local key fake_bin output version expected_mode skipped
  local -a cases=("4.3:reserve" "3.81:reserve" "4.4.1:pool" "5.0:pool" "bmake-nonsense:reserve")
  local entry

  for entry in "${cases[@]}"; do
    version="${entry%%:*}"
    expected_mode="${entry##*:}"
    key="pool-make-$version-$$"
    fake_bin="$SANDBOX/make-$version"
    mkdir -p "$fake_bin"
    if [[ "$version" == bmake-nonsense ]]; then
      printf '#!/usr/bin/env bash\nprintf "not a gnu make\\n"\n' >"$fake_bin/make"
    else
      printf '#!/usr/bin/env bash\nprintf "GNU Make %s\\n"\n' "$version" >"$fake_bin/make"
    fi
    chmod +x "$fake_bin/make"

    output="$(HARNESS_TEST_MAKE_ON_PATH=1 PATH="$fake_bin:$PATH" \
      print_cargo_env_with_pool_key "$key")"
    stop_pool_for_key "$key"
    skipped="$(awk -F= '$1 == "JOBSERVER_SKIPPED" { print $2 }' <<<"$output")"

    if ! assert_line "JOBSERVER=$expected_mode" "$output"; then
      fail "make $version should give $expected_mode: $(grep '^JOBSERVER=' <<<"$output")"
      return
    fi
    if [[ "$expected_mode" == reserve && "$skipped" != "old-make" ]]; then
      fail "make $version fell back without naming why: JOBSERVER_SKIPPED=$skipped"
      return
    fi
    if [[ "$expected_mode" == pool && -n "$skipped" ]]; then
      fail "make $version attached but claimed a skip: JOBSERVER_SKIPPED=$skipped"
      return
    fi
  done
  pass "a make too old for a fifo endpoint keeps the static reserve"
}

scenario_pool_endpoint_never_reaches_make() {
  local key="pool-make-$$"
  local output makeflags endpoint probe status=0

  output="$(print_cargo_env_with_pool_key "$key")"
  stop_pool_for_key "$key"
  makeflags="$(awk -F= '$1 == "MAKEFLAGS" { print substr($0, index($0, "=") + 1) }' <<<"$output")"
  endpoint="$(awk -F= '$1 == "CARGO_MAKEFLAGS" { print substr($0, index($0, "=") + 1) }' <<<"$output")"

  if [[ "$endpoint" != *--jobserver-auth=fifo:* ]]; then
    fail "the pool endpoint never reached CARGO_MAKEFLAGS: $endpoint"
    return
  fi
  # GNU make below 4.4 does not ignore a fifo endpoint, it dies on one: 4.3,
  # which Ubuntu 24.04 ships, exits 2 with "internal error: invalid
  # --jobserver-auth string". Anything a build script shells out to inherits
  # this environment, so the endpoint has to stay out of every name make reads.
  if [[ -n "$makeflags" ]]; then
    fail "the pool endpoint reached MAKEFLAGS: $makeflags"
    return
  fi

  if command -v make >/dev/null 2>&1; then
    probe="$SANDBOX/jobserver-probe.mk"
    printf 'all:\n\t@true\n' >"$probe"
    MAKEFLAGS="$makeflags" CARGO_MAKEFLAGS="$endpoint" \
      make -f "$probe" >/dev/null 2>&1 || status=$?
    if (( status != 0 )); then
      fail "make died under the exported environment (exit $status)"
      return
    fi
  fi
  pass "the pool endpoint never reaches make"
}

scenario_reserve_drops_an_inherited_jobserver() {
  local key="pool-inherited-$$"
  local output
  # A stale endpoint is the reachable case: this script exports exactly this
  # shape, and a child inheriting one whose pool has died would attach, get no
  # tokens, and build serially while CARGO_BUILD_JOBS advertised a full share.
  # Every variable the jobserver crate consults, because it honours the first
  # one it finds and leaving any behind reinstates the stale pool.
  output="$(print_cargo_env_with_pool_key "$key" \
    env HARNESS_JOBSERVER=0 \
    "MAKEFLAGS=-j9 --jobserver-auth=fifo:$SANDBOX/not-a-pool" \
    "MFLAGS=-j9 --jobserver-auth=fifo:$SANDBOX/not-a-pool" \
    "CARGO_MAKEFLAGS=-j9 --jobserver-auth=fifo:$SANDBOX/not-a-pool")"
  stop_pool_for_key "$key"

  if ! assert_line "JOBSERVER=reserve" "$output"; then
    fail "inherited jobserver did not fall back: $(grep '^JOBSERVER=' <<<"$output")"
    return
  fi
  if ! assert_line "MAKEFLAGS=" "$output" || ! assert_line "CARGO_MAKEFLAGS=" "$output"; then
    fail "reserve kept an inherited jobserver: $(grep -E '^(CARGO_)?MAKEFLAGS=' <<<"$output")"
    return
  fi
  pass "the reserve drops an inherited jobserver"
}

scenario_jobserver_absent_falls_back_to_the_reserve() {
  local key="pool-absent-$$"
  local output share cpu expected
  output="$(print_cargo_env_with_pool_key "$key" env HARNESS_JOBSERVER=0)"
  stop_pool_for_key "$key"

  share="$(agent_build_share)" || return
  cpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.logicalcpu)"
  expected=$(((cpu + share - 1) / share))

  if ! assert_line "JOBSERVER=reserve" "$output"; then
    fail "disabled jobserver did not fall back: $(grep '^JOBSERVER=' <<<"$output")"
    return
  fi
  if ! assert_line "CARGO_MAKEFLAGS=" "$output"; then
    fail "disabled jobserver still exported an endpoint: $(grep '^CARGO_MAKEFLAGS=' <<<"$output")"
    return
  fi
  if ! assert_line "CARGO_BUILD_JOBS=$expected" "$output"; then
    fail "fallback lost the static reserve: $(grep '^CARGO_BUILD_JOBS=' <<<"$output")"
    return
  fi
  pass "an unavailable pool falls back to the static reserve"
}

scenario_explicit_job_override_beats_the_pool() {
  local key="pool-override-$$"
  local output
  output="$(print_cargo_env_with_pool_key "$key" env HARNESS_CARGO_JOBS=3)"
  stop_pool_for_key "$key"

  if ! assert_line "CARGO_BUILD_JOBS=3" "$output"; then
    fail "explicit job override was overridden by the pool: $(grep '^CARGO_BUILD_JOBS=' <<<"$output")"
    return
  fi
  pass "an explicit job override still beats the pool"
}

print_cargo_env_without_tmpdir() {
  local fake_bin="$1" sccache_bin="$2" session="$3"
  (
    unset SCCACHE_SERVER_UDS SCCACHE_SERVER_PORT SCCACHE_NO_DAEMON
    unset SCCACHE_BASEDIRS SCCACHE_IDLE_TIMEOUT SCCACHE_CACHE_SIZE SCCACHE_VERSION
    unset HARNESS_SCCACHE_TMPDIR TMPDIR
    unset CARGO_TARGET_DIR HARNESS_CARGO_TARGET_DIR
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
    unset CARGO_TARGET_DIR HARNESS_CARGO_TARGET_DIR
    unset CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
    unset GEMINI_SESSION_ID COPILOT_SESSION_ID OPENCODE_SESSION_ID
    if [[ -n "$configured_tmpdir" ]]; then
      export TMPDIR="$configured_tmpdir"
    else
      unset TMPDIR
    fi
    # These scenarios are about TMPDIR, target dirs and sccache, and the pool
    # key would otherwise fall through to the real repository root - attaching
    # to, or spawning, a supervisor on the developer's own pool and waiting out
    # the startup timeout on every call.
    SCCACHE_BIN="$SANDBOX/missing-sccache" \
      RUSTC_WRAPPER='' \
      CODEX_SESSION_ID="$session_id" \
      HARNESS_CARGO_SKIP_LEASE=1 \
      HARNESS_CARGO_ACTIVE_BUILD_COUNT=1 \
      HARNESS_JOBSERVER=0 \
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
  local cpu_count=24 share expected_agent_jobs
  # An agent that starts alone still has to leave room for agents that join
  # later, because the lease count it saw can only shrink its share, never
  # grow it back.
  if ! share="$(agent_build_share)"; then
    fail "agent build share is missing or out of range"
    return
  fi
  expected_agent_jobs=$(((cpu_count + share - 1) / share))
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

  # Pin the fallback. With a pool reachable the token count governs instead,
  # and this scenario is about what happens when there is no pool.
  agent_output="$(
    PATH="$fake_bin:$PATH" \
      CARGO_BUILD_JOBS='' \
      HARNESS_CARGO_JOBS='' \
      HARNESS_JOBSERVER=0 \
      print_tmpdir_env "cargo-local-all-cpus-agent-$$"
  )"
  local_output="$(
    unset CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
    unset GEMINI_SESSION_ID COPILOT_SESSION_ID OPENCODE_SESSION_ID
    PATH="$fake_bin:$PATH" \
      CARGO_BUILD_JOBS='' \
      HARNESS_CARGO_JOBS='' \
      HARNESS_JOBSERVER=0 \
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

scenario_agent_jobs_hold_their_reserved_share() {
  local fake_bin="$SANDBOX/curve-bin"
  local cpu_count=24 share reserved n jobs observed="" beyond="" problems=""
  if ! share="$(agent_build_share)"; then
    fail "agent build share is missing or out of range"
    return
  fi
  reserved=$(((cpu_count + share - 1) / share))
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

  # Probe both sides of the reserve. Up to it the share must stay flat, because
  # the reserve already assumes that many agents and dividing again starved
  # every late arrival. Past it the lease count is the better estimate, so the
  # share has to start falling - a reserve that never shrinks would let a
  # crowded host hand out far more jobs than it has CPUs.
  for n in $(seq 1 $((share * 2))); do
    jobs="$(
      unset CODEX_THREAD_ID CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
      unset GEMINI_SESSION_ID COPILOT_SESSION_ID OPENCODE_SESSION_ID
      PATH="$fake_bin:$PATH" \
        CARGO_BUILD_JOBS='' \
        HARNESS_CARGO_JOBS='' \
        CODEX_SESSION_ID="cargo-local-curve-$$" \
        SCCACHE_BIN="$SANDBOX/missing-sccache" \
        RUSTC_WRAPPER='' \
        HARNESS_JOBSERVER=0 \
        HARNESS_CARGO_SKIP_LEASE=1 \
        HARNESS_CARGO_ACTIVE_BUILD_COUNT="$n" \
        "$ROOT/scripts/cargo-local.sh" --print-env \
        | awk -F= '$1 == "CARGO_BUILD_JOBS" { print substr($0, index($0, "=") + 1) }'
    )"
    [[ "$jobs" =~ ^[0-9]+$ ]] || { problems="$problems $n:non-numeric($jobs)"; continue; }
    observed="$observed $n:$jobs"
    if (( n <= share )); then
      (( jobs == reserved )) || problems="$problems $n:$jobs!=$reserved"
    else
      beyond="$jobs"
      (( jobs <= reserved )) || problems="$problems $n:$jobs>reserve"
      (( jobs >= 1 )) || problems="$problems $n:$jobs<1"
    fi
  done

  # The reserve has to actually give way once the observed count passes it.
  if [[ -n "$beyond" ]] && (( beyond >= reserved )); then
    problems="$problems reserve-never-shrinks(at-$((share * 2)):$beyond)"
  fi

  if [[ -z "$problems" ]]; then
    pass "agent job share holds the reserve, then yields to the lease count"
  else
    fail "agent job curve wrong:$problems (reserved=$reserved observed:$observed)"
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

# The Cleanup closeout step reads this to find the lane it has to reclaim, so a
# path that disagrees with the one builds actually use would send it at the
# wrong directory, or at nothing.
scenario_print_target_dir_matches_the_build_dir() {
  local dumped printed

  dumped="$(
    print_tmpdir_env "cargo-local-print-dir-$$" \
      | awk -F= '$1 == "CARGO_TARGET_DIR" { print substr($0, index($0, "=") + 1) }'
  )"
  printed="$(
    (
      unset CARGO_TARGET_DIR HARNESS_CARGO_TARGET_DIR
      SCCACHE_BIN="$SANDBOX/missing-sccache" \
        RUSTC_WRAPPER='' \
        CODEX_SESSION_ID="cargo-local-print-dir-$$" \
        "$ROOT/scripts/cargo-local.sh" --print-target-dir
    )
  )"

  if [[ -n "$printed" ]] \
    && [[ "$printed" == "$dumped" ]] \
    && [[ "$(printf '%s' "$printed" | wc -l | tr -d ' ')" == "0" ]]; then
    pass "--print-target-dir names the dir builds use"
  else
    fail "--print-target-dir disagrees: printed=$printed dumped=$dumped"
  fi
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
    && assert_line "SCCACHE_BASEDIRS=$COMMON_REPO_ROOT" "$output" \
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

scenario_live_socket_survives_the_sweep() {
  local fake_bin="$SANDBOX/livesock-bin"
  local tmpdir="$SANDBOX/livesock-tmp"
  local socket_dir="$tmpdir/harness-sccache"
  local live_socket="$socket_dir/live.sock"
  local stale_socket="$socket_dir/stale.sock"
  mkdir -p "$fake_bin" "$socket_dir"
  write_fake_sccache "$fake_bin/sccache" "0.16.0"
  # lsof 4.95 prints the name field as "<path> type=STREAM"; 4.91 printed the
  # path alone. Reading only the older shape matched nothing on a modern lsof,
  # so every live socket was unlinked and the next client then found no server
  # and started a second one.
  cat >"$fake_bin/lsof" <<EOF
#!/usr/bin/env bash
printf 'p1\n'
printf 'n%s type=STREAM\n' "$live_socket"
EOF
  chmod +x "$fake_bin/lsof"
  : >"$live_socket"
  : >"$stale_socket"

  print_cargo_env "$fake_bin" "$fake_bin/sccache" "$tmpdir" >/dev/null
  if [[ -e "$live_socket" ]] && [[ ! -e "$stale_socket" ]]; then
    pass "the sweep keeps a live socket and unlinks a stale one"
  else
    fail "sweep verdict wrong: live=$([[ -e "$live_socket" ]] && echo kept || echo unlinked) stale=$([[ -e "$stale_socket" ]] && echo kept || echo unlinked)"
  fi
}

scenario_sccache_socket_is_shared_across_checkouts() {
  local base="$ROOT/tmp/cargo-local-checkouts-$$"
  local fake_bin="$SANDBOX/checkout-bin"
  local co out a_sock="" b_sock="" a_target="" b_target=""
  mkdir -p "$fake_bin"
  write_fake_sccache "$fake_bin/sccache" "0.16.0"

  # Two checkout roots under one git common root. The socket follows the
  # repository, so it must match while the build caches stay distinct.
  for co in alpha beta; do
    mkdir -p "$base/$co/scripts/lib"
    cp "$ROOT/scripts/cargo-local.sh" "$base/$co/scripts/cargo-local.sh"
    cp "$ROOT/scripts/lib/"*.sh "$base/$co/scripts/lib/"
    chmod +x "$base/$co/scripts/cargo-local.sh"

    out="$(
      unset SCCACHE_SERVER_UDS SCCACHE_SERVER_PORT SCCACHE_NO_DAEMON
      unset SCCACHE_BASEDIRS SCCACHE_IDLE_TIMEOUT SCCACHE_CACHE_SIZE SCCACHE_VERSION
      unset HARNESS_SCCACHE_TMPDIR
      unset CARGO_TARGET_DIR HARNESS_CARGO_TARGET_DIR
      unset CODEX_THREAD_ID CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
      unset GEMINI_SESSION_ID COPILOT_SESSION_ID OPENCODE_SESSION_ID
      SCCACHE_BIN="$fake_bin/sccache" \
        RUSTC_WRAPPER='' \
        CODEX_SESSION_ID="cargo-local-checkout-$$" \
        HARNESS_CARGO_SKIP_LEASE=1 \
        HARNESS_CARGO_ACTIVE_BUILD_COUNT=1 \
        "$base/$co/scripts/cargo-local.sh" --print-env
    )"
    if [[ "$co" == alpha ]]; then
      a_sock="$(awk -F= '$1 == "SCCACHE_SERVER_UDS" { print substr($0, index($0, "=") + 1) }' <<<"$out")"
      a_target="$(awk -F= '$1 == "CARGO_TARGET_DIR" { print substr($0, index($0, "=") + 1) }' <<<"$out")"
    else
      b_sock="$(awk -F= '$1 == "SCCACHE_SERVER_UDS" { print substr($0, index($0, "=") + 1) }' <<<"$out")"
      b_target="$(awk -F= '$1 == "CARGO_TARGET_DIR" { print substr($0, index($0, "=") + 1) }' <<<"$out")"
    fi
  done

  if [[ -n "$a_sock" ]] \
    && [[ "$a_target" != "$b_target" ]] \
    && [[ "$a_sock" == "$b_sock" ]]; then
    pass "one sccache socket per repository across separate checkouts"
  else
    fail "socket did not follow the repository: a=$a_sock b=$b_sock targets=$a_target,$b_target"
  fi

  rm -rf "$base"
}

scenario_symlinked_repo_tmpdir_base_is_rejected() {
  local fake_bin="$SANDBOX/symbase-bin"
  local base="$COMMON_REPO_ROOT/target/.cargo-local/tmp"
  local stash="$COMMON_REPO_ROOT/target/.cargo-local/tmp-stashed-$$"
  local real_touch output status moved=0
  real_touch="$(command -v touch)"
  mkdir -p "$fake_bin" "$COMMON_REPO_ROOT/target/.cargo-local"
  cat >"$fake_bin/touch" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == /tmp/* ]]; then
    exit 1
  fi
done
exec "$HARNESS_TEST_REAL_TOUCH" "$@"
EOF
  chmod +x "$fake_bin/touch"

  if [[ -e "$base" || -L "$base" ]]; then
    mv "$base" "$stash"
    moved=1
  fi
  # mkdir -p would adopt this happily; only the base check catches it.
  ln -sfn "$SANDBOX" "$base"

  set +e
  output="$(PATH="$fake_bin:$PATH" HARNESS_TEST_REAL_TOUCH="$real_touch" \
    print_tmpdir_env "cargo-local-symbase-$$" 2>&1)"
  status=$?
  set -e

  rm -f "$base"
  if (( moved == 1 )); then
    mv "$stash" "$base"
  fi

  if (( status != 0 )) \
    && assert_contains "failed to prepare private TMPDIR base" "$output"; then
    pass "a symlinked in-repo TMPDIR base is rejected"
  else
    fail "symlinked in-repo TMPDIR base was accepted (status=$status): $output"
  fi
}

scenario_unsafe_socket_dir_disables_sccache() {
  local fake_bin="$SANDBOX/unsafe-sock-bin"
  local short_tmp="/tmp/hs-$$"
  local output
  mkdir -p "$fake_bin" "$short_tmp"
  write_fake_sccache "$fake_bin/sccache" "0.16.0"
  # A symlinked socket root is exactly what prepare_private_tmpdir refuses.
  ln -sfn "$SANDBOX" "$short_tmp/harness-sccache"

  output="$(print_cargo_env "$fake_bin" "$fake_bin/sccache" "$short_tmp")"

  # Leaving sccache enabled here would hand it whatever default endpoint it
  # picks, which can be a localhost port other local users can reach.
  if assert_line "SCCACHE_BIN=" "$output" \
    && assert_line "CACHE_MODE=none" "$output" \
    && assert_line "SCCACHE_SERVER_UDS=" "$output"; then
    pass "an unsafe socket directory disables sccache instead of falling back"
  else
    fail "sccache stayed enabled without a private socket dir: $output"
  fi

  rm -rf "$short_tmp"
}

scenario_repo_tmpdir_fallback_is_session_scoped() {
  local fake_bin="$SANDBOX/no-tmp-bin"
  local real_touch first second first_tmp second_tmp
  real_touch="$(command -v touch)"
  mkdir -p "$fake_bin"
  # Force the in-repo TMPDIR branch by making every /tmp probe fail.
  cat >"$fake_bin/touch" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == /tmp/* ]]; then
    exit 1
  fi
done
exec "$HARNESS_TEST_REAL_TOUCH" "$@"
EOF
  chmod +x "$fake_bin/touch"

  first="$(PATH="$fake_bin:$PATH" HARNESS_TEST_REAL_TOUCH="$real_touch" \
    print_tmpdir_env "cargo-local-repofb-a-$$")"
  second="$(PATH="$fake_bin:$PATH" HARNESS_TEST_REAL_TOUCH="$real_touch" \
    print_tmpdir_env "cargo-local-repofb-b-$$")"
  first_tmp="$(awk -F= '$1 == "TMPDIR" { print substr($0, index($0, "=") + 1) }' <<<"$first")"
  second_tmp="$(awk -F= '$1 == "TMPDIR" { print substr($0, index($0, "=") + 1) }' <<<"$second")"

  # It also has to carry the same ownership and mode guarantees as the /tmp
  # fallback, or the session scoping above is only skin deep.
  if [[ "$first_tmp" == "$COMMON_REPO_ROOT/target/.cargo-local/tmp/"* ]] \
    && [[ "$first_tmp" != "$second_tmp" ]] \
    && [[ ! -L "${first_tmp%/}" ]] \
    && [[ -O "${first_tmp%/}" ]] \
    && [[ "$(dir_mode "${first_tmp%/}")" == "700" ]]; then
    pass "in-repo TMPDIR fallback stays session scoped and private"
  else
    fail "in-repo TMPDIR fallback was not session scoped or not private: a=$first_tmp b=$second_tmp"
  fi

  rm -rf "${first_tmp%/}" "${second_tmp%/}"
}

scenario_cache_wrapper_shortens_long_tmpdir() {
  local fake_bin="$SANDBOX/wrapper-bin"
  local long_tmp
  local observed_tmp="$SANDBOX/observed-tmp"
  local observed_size="$SANDBOX/observed-size"
  long_tmp="$SANDBOX/$(printf 'long-path-%.0s' {1..10})"
  mkdir -p "$fake_bin" "$long_tmp"
  cat >"$fake_bin/sccache" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
  printf 'wrapper repeated the resolved version probe\n' >&2
  exit 92
fi
printf '%s\n' "\${TMPDIR:-}" >"$observed_tmp"
printf '%s\n' "\${SCCACHE_CACHE_SIZE:-UNSET}" >"$observed_size"
exit 0
EOF
  chmod +x "$fake_bin/sccache"

  TMPDIR="$long_tmp/" SCCACHE_BIN="$fake_bin/sccache" SCCACHE_VERSION="0.16.0" \
    "$ROOT/scripts/rustc-cache-wrapper.sh" fake-rustc -vV
  # A server pins its cache limit at startup and a plain Cargo or Xcode build is
  # often what starts it, so the wrapper has to carry a default of its own.
  if [[ "$(<"$observed_tmp")" == "/tmp/" ]] \
    && [[ "$(<"$observed_size")" != "UNSET" ]]; then
    pass "cache wrapper shortens long TMPDIR paths and defaults the cache size"
  else
    fail "cache wrapper env wrong: tmpdir=$(<"$observed_tmp") size=$(<"$observed_size")"
  fi

  # An explicit size must win over the wrapper's default.
  TMPDIR="$long_tmp/" SCCACHE_BIN="$fake_bin/sccache" SCCACHE_VERSION="0.16.0" \
    SCCACHE_CACHE_SIZE="7G" "$ROOT/scripts/rustc-cache-wrapper.sh" fake-rustc -vV
  if [[ "$(<"$observed_size")" == "7G" ]]; then
    pass "cache wrapper preserves an explicit cache size"
  else
    fail "cache wrapper overrode an explicit cache size: $(<"$observed_size")"
  fi
}

# A listener on the socket, which is what separates a started server from a
# recorded intention to start one. Without something to connect to, the probe in
# cargo-local would report "no server" forever and every scenario below would
# pass while the code under test started a server per invocation.
write_fake_socket_holder() {
  local path="$1"
  cat >"$path" <<'PY'
import os, socket, sys, time

socket_path, pid_file = sys.argv[1], sys.argv[2]
try:
    os.unlink(socket_path)
except OSError:
    pass
listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(socket_path)
listener.listen(16)
with open(pid_file, "a", encoding="utf-8") as handle:
    handle.write(f"{os.getpid()}\n")
time.sleep(120)
PY
}

write_fake_sccache_server() {
  local path="$1" log="$2" holder="$3" pid_file="$4"
  cat >"$path" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
  printf 'sccache 0.16.0\n'
  exit 0
fi
if [[ "\${1:-}" == "--start-server" ]]; then
  printf 'start-server\n' >>"$log"
  python3 "$holder" "\$SCCACHE_SERVER_UDS" "$pid_file" >/dev/null 2>&1 &
  # The real binary returns only once the server is listening, and a fake that
  # returns earlier would let the next invocation see nothing and start again.
  for _ in {1..200}; do
    if [[ -S "\$SCCACHE_SERVER_UDS" ]]; then
      exit 0
    fi
    sleep 0.05
  done
  exit 1
fi
printf 'unexpected fake sccache invocation: %s\n' "\$*" >&2
exit 91
EOF
  chmod +x "$path"
}

write_logging_cargo() {
  local path="$1" log="$2"
  cat >"$path" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-V" ]]; then
  printf 'cargo 1.0.0\n'
  exit 0
fi
printf 'cargo\n' >>"$log"
EOF
  chmod +x "$path"
}

# A short TMPDIR outside the sandbox on purpose. The sandbox path is long enough
# that configure_sccache_socket would fall back to the shared /tmp root, and the
# socket id is a hash of this repository - so these scenarios would bind, and
# then kill, the developer's own sccache socket.
prestart_tmpdir() {
  printf '/tmp/cl-prestart-%s\n' "$$"
}

run_cargo_local_prestart() {
  local fake_bin="$1" cargo_bin="$2"
  shift 2
  (
    unset SCCACHE_SERVER_UDS SCCACHE_SERVER_PORT SCCACHE_NO_DAEMON
    unset SCCACHE_BASEDIRS SCCACHE_IDLE_TIMEOUT SCCACHE_CACHE_SIZE SCCACHE_VERSION
    unset HARNESS_SCCACHE_TMPDIR
    unset CARGO_TARGET_DIR HARNESS_CARGO_TARGET_DIR
    unset MAKEFLAGS MFLAGS CARGO_MAKEFLAGS
    PATH="$fake_bin:$PATH" \
      TMPDIR="$(prestart_tmpdir)/" \
      SCCACHE_BIN="$fake_bin/sccache" \
      RUSTC_WRAPPER='' \
      HARNESS_CARGO_BIN="$cargo_bin" \
      HARNESS_JOBSERVER=0 \
      CODEX_SESSION_ID="cargo-local-prestart-$$" \
      HARNESS_CARGO_SKIP_LEASE=1 \
      HARNESS_CARGO_ACTIVE_BUILD_COUNT=1 \
      "$ROOT/scripts/cargo-local.sh" "$@" >/dev/null 2>&1
  )
}

prestart_socket_path() {
  local fake_bin="$1"
  (
    unset SCCACHE_SERVER_UDS SCCACHE_SERVER_PORT SCCACHE_NO_DAEMON
    unset SCCACHE_BASEDIRS SCCACHE_IDLE_TIMEOUT SCCACHE_CACHE_SIZE SCCACHE_VERSION
    unset HARNESS_SCCACHE_TMPDIR
    unset CARGO_TARGET_DIR HARNESS_CARGO_TARGET_DIR
    PATH="$fake_bin:$PATH" \
      TMPDIR="$(prestart_tmpdir)/" \
      SCCACHE_BIN="$fake_bin/sccache" \
      RUSTC_WRAPPER='' \
      HARNESS_JOBSERVER=0 \
      CODEX_SESSION_ID="cargo-local-prestart-$$" \
      HARNESS_CARGO_SKIP_LEASE=1 \
      HARNESS_CARGO_ACTIVE_BUILD_COUNT=1 \
      "$ROOT/scripts/cargo-local.sh" --print-env 2>/dev/null
  ) | awk -F= '$1 == "SCCACHE_SERVER_UDS" { print substr($0, index($0, "=") + 1) }'
}

stop_prestart_servers() {
  local pid_file="$1" pid waited
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill "$pid" 2>/dev/null || true
    # A holder still alive when the scenario removes its directory keeps
    # listening on an unlinked path for the rest of its sleep, and the next
    # scenario inherits it as a live socket nothing in that scenario created.
    waited=0
    while kill -0 "$pid" 2>/dev/null && (( waited < 40 )); do
      sleep 0.05
      waited=$((waited + 1))
    done
    kill -9 "$pid" 2>/dev/null || true
  done <"$pid_file"
  : >"$pid_file"
}

scenario_sccache_server_is_started_before_cargo() {
  local fake_bin="$SANDBOX/prestart-bin"
  local log="$SANDBOX/prestart-log"
  local pid_file="$SANDBOX/prestart-pids"
  local tmpdir starts first_line
  tmpdir="$(prestart_tmpdir)"
  mkdir -p "$fake_bin" "$tmpdir"
  : >"$log"
  : >"$pid_file"
  write_fake_socket_holder "$SANDBOX/socket-holder.py"
  write_fake_sccache_server "$fake_bin/sccache" "$log" "$SANDBOX/socket-holder.py" "$pid_file"
  write_logging_cargo "$fake_bin/cargo" "$log"

  run_cargo_local_prestart "$fake_bin" "$fake_bin/cargo" build --lib
  run_cargo_local_prestart "$fake_bin" "$fake_bin/cargo" build --lib
  stop_prestart_servers "$pid_file"

  starts="$(grep -c '^start-server$' "$log" || true)"
  first_line="$(head -1 "$log")"
  rm -rf "$tmpdir"

  # Twice, because the second run is the one that proves the probe works: a
  # server already listening must not be replaced by another one.
  if [[ "$starts" == "1" ]] && [[ "$first_line" == "start-server" ]]; then
    pass "one sccache server is started, before cargo runs"
  else
    fail "sccache prestart wrong: $starts start(s), log begins with '$first_line'"
  fi
}

scenario_concurrent_builds_start_one_sccache_server() {
  local fake_bin="$SANDBOX/concurrent-prestart-bin"
  local log="$SANDBOX/concurrent-prestart-log"
  local pid_file="$SANDBOX/concurrent-prestart-pids"
  local tmpdir starts builds
  tmpdir="$(prestart_tmpdir)"
  mkdir -p "$fake_bin" "$tmpdir"
  : >"$log"
  : >"$pid_file"
  write_fake_socket_holder "$SANDBOX/concurrent-socket-holder.py"
  write_fake_sccache_server \
    "$fake_bin/sccache" "$log" "$SANDBOX/concurrent-socket-holder.py" "$pid_file"
  write_logging_cargo "$fake_bin/cargo" "$log"

  # The burst is the whole bug: without serialisation every one of these sees no
  # server, starts one, and all but the last are orphaned on the same path.
  for _ in {1..8}; do
    run_cargo_local_prestart "$fake_bin" "$fake_bin/cargo" build --lib &
  done
  wait
  stop_prestart_servers "$pid_file"

  starts="$(grep -c '^start-server$' "$log" || true)"
  builds="$(grep -c '^cargo$' "$log" || true)"
  rm -rf "$tmpdir"

  if [[ "$starts" == "1" ]] && [[ "$builds" == "8" ]]; then
    pass "a burst of concurrent builds starts exactly one sccache server"
  else
    fail "concurrent prestart wrong: $starts server start(s) for $builds builds"
  fi
}

scenario_unusable_python_falls_back_to_the_socket_file() {
  local fake_bin="$SANDBOX/nopython-prestart-bin"
  local log="$SANDBOX/nopython-prestart-log"
  local pid_file="$SANDBOX/nopython-prestart-pids"
  local tmpdir socket starts
  tmpdir="$(prestart_tmpdir)"
  mkdir -p "$fake_bin" "$tmpdir"
  : >"$log"
  : >"$pid_file"
  write_fake_socket_holder "$SANDBOX/nopython-socket-holder.py"
  write_fake_sccache_server \
    "$fake_bin/sccache" "$log" "$SANDBOX/nopython-socket-holder.py" "$pid_file"
  write_logging_cargo "$fake_bin/cargo" "$log"

  # Stand the server up with a working python3, then take python3 away for the
  # run under test. macOS ships a /usr/bin/python3 that behaves like this until
  # the command line tools are installed: present on PATH, exit 1, no output.
  socket="$(prestart_socket_path "$fake_bin")"
  if [[ -z "$socket" ]]; then
    fail "could not resolve the prestart socket path"
    rm -rf "$tmpdir"
    return
  fi
  python3 "$SANDBOX/nopython-socket-holder.py" "$socket" "$pid_file" >/dev/null 2>&1 &
  local waited=0
  while [[ ! -S "$socket" ]] && (( waited < 200 )); do
    sleep 0.05
    waited=$((waited + 1))
  done
  printf '#!/usr/bin/env bash\nexit 1\n' >"$fake_bin/python3"
  chmod +x "$fake_bin/python3"

  run_cargo_local_prestart "$fake_bin" "$fake_bin/cargo" build --lib
  stop_prestart_servers "$pid_file"
  rm -f "$fake_bin/python3"

  starts="$(grep -c '^start-server$' "$log" || true)"
  rm -rf "$tmpdir"

  # A probe that cannot run must not read as "no server": starting a second one
  # beside a live one is the failure the prestart exists to prevent.
  if [[ "$starts" == "0" ]]; then
    pass "an unusable python3 falls back to the socket file rather than starting a server"
  else
    fail "an unusable python3 started $starts sccache server(s) next to a live one"
  fi
}

scenario_query_commands_start_no_sccache_server() {
  local fake_bin="$SANDBOX/query-prestart-bin"
  local log="$SANDBOX/query-prestart-log"
  local pid_file="$SANDBOX/query-prestart-pids"
  local tmpdir starts
  tmpdir="$(prestart_tmpdir)"
  mkdir -p "$fake_bin" "$tmpdir"
  : >"$log"
  : >"$pid_file"
  write_fake_socket_holder "$SANDBOX/query-socket-holder.py"
  write_fake_sccache_server \
    "$fake_bin/sccache" "$log" "$SANDBOX/query-socket-holder.py" "$pid_file"
  write_logging_cargo "$fake_bin/cargo" "$log"

  run_cargo_local_prestart "$fake_bin" "$fake_bin/cargo" --print-env
  run_cargo_local_prestart "$fake_bin" "$fake_bin/cargo" --print-target-dir
  stop_prestart_servers "$pid_file"

  starts="$(grep -c '^start-server$' "$log" || true)"
  rm -rf "$tmpdir"

  # Asking what the environment would be is not a build, and leaving a daemon
  # behind for a question is a surprise every caller of these would inherit.
  if [[ "$starts" == "0" ]]; then
    pass "environment queries start no sccache server"
  else
    fail "an environment query started $starts sccache server(s)"
  fi
}

scenario_jobserver_pool_takes_over_build_sizing
scenario_jobserver_absent_falls_back_to_the_reserve
scenario_reserve_drops_an_inherited_jobserver
scenario_pool_endpoint_never_reaches_make
scenario_old_make_keeps_the_pool_at_arms_length
scenario_explicit_job_override_beats_the_pool
scenario_nextest_build_phase_keeps_the_whole_pool
scenario_build_only_flag_precedes_a_separator
scenario_nextest_detection_handles_toolchain_and_list
scenario_nextest_detection_skips_global_flag_values
scenario_missing_tmpdir_uses_short_external_fallback
scenario_concurrent_tmpdir_creation_is_idempotent
scenario_unusable_tmpdir_uses_short_external_fallback
scenario_usable_tmpdir_is_preserved
scenario_agent_build_jobs_leave_room_for_later_arrivals
scenario_agent_jobs_hold_their_reserved_share
scenario_target_dir_is_shared_across_sessions
scenario_print_target_dir_matches_the_build_dir
scenario_sccache_socket_survives_session_scoped_tmpdir
scenario_sccache_socket_is_shared_across_checkouts
scenario_repo_tmpdir_fallback_is_session_scoped
scenario_symlinked_repo_tmpdir_base_is_rejected
scenario_unsafe_socket_dir_disables_sccache
scenario_single_thread_nextest_override_is_rejected
scenario_noncanonical_nextest_override_is_rejected
scenario_supported_sccache_is_resolved_once
scenario_old_explicit_sccache_is_disabled
scenario_failed_lsof_preserves_unknown_sockets
scenario_live_socket_survives_the_sweep
scenario_sccache_server_is_started_before_cargo
scenario_concurrent_builds_start_one_sccache_server
scenario_unusable_python_falls_back_to_the_socket_file
scenario_query_commands_start_no_sccache_server
scenario_cache_wrapper_shortens_long_tmpdir

printf 'cargo-local tests: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT" >&2
(( FAIL_COUNT == 0 ))
