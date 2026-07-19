#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
export HARNESS_RELEASE_HOST_OS=Linux
# shellcheck source=scripts/lib/release-set.sh
source "$ROOT/scripts/lib/release-set.sh"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/release-install-test-$$.XXXXXX")"
PASS_COUNT=0
FAIL_COUNT=0
CURRENT_TEST=""
HARNESS_BINARIES=("${HARNESS_RELEASE_BINARIES[@]}")
RELEASE_BINARIES=("${HARNESS_RELEASE_ALL_BINARIES[@]}")
TEST_WORKER_PIDS=()

cleanup() {
  local pid
  for pid in "${TEST_WORKER_PIDS[@]}"; do
    command kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  command rm -rf "$SANDBOX"
}
trap cleanup EXIT

start_test() {
  CURRENT_TEST="$1"
  printf 'RUN:  %s\n' "$CURRENT_TEST" >&2
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '  PASS: %s\n' "$CURRENT_TEST" >&2
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '  FAIL: %s - %s\n' "$CURRENT_TEST" "$*" >&2
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  if command grep -Fq -- "$needle" <<<"$haystack"; then
    return 0
  fi
  fail "missing '$needle' in: $haystack"
  return 1
}

assert_not_contains() {
  local needle="$1"
  local haystack="$2"
  if command grep -Fq -- "$needle" <<<"$haystack"; then
    fail "unexpected '$needle' in: $haystack"
    return 1
  fi
  return 0
}

write_fake_cargo() {
  local fake_bin="$1"
  command mkdir -p "$fake_bin"
  command cat >"$fake_bin/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-V" ]]; then
  printf 'cargo 1.99.0-test\n'
  exit 0
fi

args="$*"
leaf="${HARNESS_RELEASE_BUILD_LEAF:-unknown}"
printf 'start leaf=%s jobs=%s target_dir=%s build_dir=%s pid=%s args=%s\n' \
  "$leaf" "${CARGO_BUILD_JOBS:-}" "${CARGO_TARGET_DIR:-}" \
  "${CARGO_BUILD_BUILD_DIR:-}" "$$" "$args" \
  >>"$FAKE_CARGO_EVENTS"
trap 'printf "term leaf=%s\n" "$leaf" >>"$FAKE_CARGO_EVENTS"; exit 143' TERM

if [[ "${FAKE_CARGO_FAIL_LEAF:-}" == "$leaf" ]]; then
  sleep "${FAKE_CARGO_FAIL_DELAY:-0.1}"
  printf 'fail leaf=%s\n' "$leaf" >>"$FAKE_CARGO_EVENTS"
  exit "${FAKE_CARGO_FAIL_STATUS:-41}"
fi
sleep "${FAKE_CARGO_SLEEP:-0.2}"
case "$leaf" in
  harness) binary=harness ;;
  daemon) binary=harness-daemon ;;
  systemd) binary=harness-systemd ;;
  bridge) binary=harness-bridge ;;
  mcp) binary=harness-mcp ;;
  hook) binary=harness-hook ;;
  codex) binary=harness-codex-acp ;;
  openrouter) binary=harness-openrouter-agent ;;
  aff) binary=aff ;;
  *) exit 2 ;;
esac
if [[ "${FAKE_CARGO_OMIT_ARTIFACT_LEAF:-}" != "$leaf" ]]; then
  mkdir -p "$CARGO_TARGET_DIR/release"
  source_path="${HARNESS_RELEASE_OUTPUT_TARGET_DIR:-}/release/$binary"
  if [[ -x "$source_path" ]]; then
    cp "$source_path" "$CARGO_TARGET_DIR/release/$binary"
  else
    printf '#!/usr/bin/env bash\nexit 0\n' >"$CARGO_TARGET_DIR/release/$binary"
    chmod +x "$CARGO_TARGET_DIR/release/$binary"
  fi
fi
printf 'finish leaf=%s\n' "$leaf" >>"$FAKE_CARGO_EVENTS"
EOF
  command chmod +x "$fake_bin/cargo"
}

write_fake_codesign() {
  local fake_bin="$1"
  command mkdir -p "$fake_bin"
  command cat >"$fake_bin/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="${*: -1}"
if [[ "$*" == *--verify* ]] \
  && [[ "$(basename -- "$path")" == "${FAKE_CODESIGN_FAIL_VERIFY_NAME:-}" ]]; then
  exit 45
fi
if [[ "$*" == *--verify* && "$*" == *-R=* ]] \
  && [[ "$(basename -- "$path")" == "${FAKE_CODESIGN_FAIL_REQUIREMENT_NAME:-}" ]]; then
  exit 46
fi
exit 0
EOF
  command chmod +x "$fake_bin/codesign"
}

write_fake_release_set() {
  local target="$1"
  local version="$2"
  local name
  command mkdir -p "$target/release"
  for name in "${RELEASE_BINARIES[@]}"; do
    command cat >"$target/release/$name" <<EOF
#!/usr/bin/env bash
name='$name'
version='$version'
case "\${1:-}" in
  --version)
    printf '%s %s\\n' "\$name" "\$version"
    ;;
  --probe)
    case "\$name" in
      harness-codex-acp|harness-openrouter-agent)
        printf '%s\\n' "\$name"
        ;;
      *) exit 2 ;;
    esac
    ;;
  --help)
    if [[ "\$name" == harness ]]; then
      printf 'Harness CLI\\n'
    else
      printf '%s\\n' "\$name"
    fi
    ;;
  *)
    exit 0
    ;;
esac
EOF
    command chmod +x "$target/release/$name"
  done
}

run_installer() {
  local sandbox="$1"
  shift
  PATH="${RUN_INSTALLER_PATH:-/usr/bin:/bin}" \
    BASH_ENV=/dev/null \
    HOME="$sandbox/home" \
    CARGO_TARGET_DIR="$sandbox/target" \
    HARNESS_INSTALL_ROOT="$sandbox/install-root" \
    HARNESS_INSTALL_BINARY_DIR="$sandbox/bin" \
    AFF_INSTALL_BINARY_DIR="$sandbox/aff-bin" \
    HARNESS_INSTALL_SKIP_CODESIGN="${HARNESS_INSTALL_SKIP_CODESIGN:-1}" \
    AFF_INSTALL_SKIP_CODESIGN="${AFF_INSTALL_SKIP_CODESIGN:-1}" \
    HARNESS_INSTALL_CLEANUP_CLI_DAEMON=0 \
    HARNESS_INSTALL_LEGACY_CONFIG_ROOT="${HARNESS_INSTALL_LEGACY_CONFIG_ROOT:-$sandbox/project}" \
    "$@"
}

assert_failed_first_install_is_clean() {
  local sandbox="$1" remaining debris
  remaining="$(find "$sandbox/install-root" -mindepth 1 -print 2>/dev/null || true)"
  if [[ -n "$remaining" ]]; then
    fail "install transaction left debris: $remaining"
    return 1
  fi
  debris="$(find "$sandbox" \
    \( -name '*.next-*' -o -name '*.rollback-*' -o -name '*.staging' \) \
    -print 2>/dev/null || true)"
  if [[ -n "$debris" ]]; then
    fail "install transaction left staged paths: $debris"
    return 1
  fi
}

scenario_build_group_allocates_one_budget() {
  start_test "release build group shares one budget across leaves"
  local sandbox="$SANDBOX/build-budget"
  local events="$sandbox/events"
  local trace="$sandbox/trace"
  local job_cap=$(( ${#HARNESS_RELEASE_ALL_BUILD_LEAVES[@]} + 2 ))
  local canonical_target
  command mkdir -p "$sandbox"
  write_fake_cargo "$sandbox/fake-bin"

  PATH="$sandbox/fake-bin:/usr/bin:/bin" \
    BASH_ENV=/dev/null \
    HARNESS_CARGO_BIN="$sandbox/fake-bin/cargo" \
    CARGO_TARGET_DIR="$sandbox/target" \
    CARGO_BUILD_JOBS="$job_cap" \
    CODEX_SESSION_ID="release-build-test-$$" \
    FAKE_CARGO_EVENTS="$events" \
    HARNESS_RELEASE_BUILD_TRACE="$trace" \
    "$ROOT/scripts/cargo-local.sh" --with-group-lease \
    "$ROOT/scripts/build-release-set.sh" all >/dev/null

  local output
  output="$(command cat "$trace")"
  local ok=1
  local index leaf expected_jobs target_count first_finish_line
  local starts_before_first_finish
  for ((index = 0; index < ${#HARNESS_RELEASE_ALL_BUILD_LEAVES[@]}; index++)); do
    leaf="${HARNESS_RELEASE_ALL_BUILD_LEAVES[index]}"
    expected_jobs=1
    (( index < 2 )) && expected_jobs=2
    assert_contains "start leaf=$leaf jobs=$expected_jobs" "$output" || ok=0
  done
  canonical_target="$(release_normalize_target_dir "$sandbox/target")"
  assert_contains "$canonical_target/.release-build/build/harness" "$output" || ok=0
  target_count="$(command sed -n 's/.* target_dir=\([^ ]*\) .*/\1/p' "$events" \
    | command sort -u | command wc -l | command tr -d ' ')"
  if (( target_count != ${#HARNESS_RELEASE_ALL_BUILD_LEAVES[@]} )); then
    fail "expected one isolated Cargo target per release leaf, got $target_count"
    ok=0
  fi
  assert_not_contains "target_dir=$canonical_target build_dir=" \
    "$(command cat "$events")" || ok=0
  assert_not_contains "build_dir=$canonical_target" \
    "$(command cat "$events")" || ok=0
  first_finish_line="$(command grep -n 'finish leaf=' "$events" \
    | command head -1 | command cut -d: -f1)"
  starts_before_first_finish="$(command sed -n "1,${first_finish_line}p" "$events" \
    | command grep -c 'start leaf=')"
  if (( starts_before_first_finish < 2 )); then
    fail "expected compiler overlap before the first leaf finished"
    ok=0
  fi
  for leaf in "${RELEASE_BINARIES[@]}"; do
    if [[ ! -x "$canonical_target/release/$leaf" ]]; then
      fail "missing published release executable $leaf"
      ok=0
    fi
  done
  assert_contains "--locked -p harness --bin harness" \
    "$(command cat "$events")" || ok=0
  assert_contains "--locked -p harness-daemon --bin harness-daemon --features tokio-console" \
    "$(command cat "$events")" || ok=0
  assert_contains "--locked -p harness-systemd --bin harness-systemd" \
    "$(command cat "$events")" || ok=0
  assert_contains "--locked --manifest-path crates/harness-codex-acp/Cargo.toml" \
    "$(command cat "$events")" || ok=0
  assert_not_contains "--workspace --bins" "$(command cat "$events")" || ok=0
  if (( ok )); then pass; fi
}

scenario_release_inventory_is_platform_aware() {
  start_test "release inventory includes systemd only on Linux"
  local sandbox="$SANDBOX/platform-inventory"
  local linux_inventory darwin_inventory
  command mkdir -p "$sandbox"

  linux_inventory="$(
    HARNESS_RELEASE_HOST_OS=Linux bash -c '
      source "$1"
      printf "binaries=%s\n" "${HARNESS_RELEASE_BINARIES[*]}"
      printf "leaves=%s\n" "${HARNESS_RELEASE_BUILD_LEAVES[*]}"
    ' bash "$ROOT/scripts/lib/release-set.sh"
  )"
  darwin_inventory="$(
    HARNESS_RELEASE_HOST_OS=Darwin bash -c '
      source "$1"
      printf "binaries=%s\n" "${HARNESS_RELEASE_BINARIES[*]}"
      printf "leaves=%s\n" "${HARNESS_RELEASE_BUILD_LEAVES[*]}"
    ' bash "$ROOT/scripts/lib/release-set.sh"
  )"

  local ok=1
  assert_contains "binaries=harness harness-daemon harness-systemd harness-bridge harness-mcp harness-hook harness-codex-acp harness-openrouter-agent" "$linux_inventory" || ok=0
  assert_contains "leaves=harness daemon systemd bridge mcp hook codex openrouter" "$linux_inventory" || ok=0
  assert_not_contains "harness-systemd" "$darwin_inventory" || ok=0
  assert_contains "binaries=harness harness-daemon harness-bridge harness-mcp harness-hook harness-codex-acp harness-openrouter-agent" "$darwin_inventory" || ok=0
  assert_contains "leaves=harness daemon bridge mcp hook codex openrouter" "$darwin_inventory" || ok=0
  if (( ok )); then pass; fi
}

scenario_darwin_excludes_systemd_and_migrates_managed_link() {
  start_test "Darwin excludes systemd and transactionally removes its managed link"
  local sandbox="$SANDBOX/darwin-systemd"
  local build_events="$sandbox/build-events"
  local old_target failed_target active_target status=0 name
  local ok=1
  command mkdir -p "$sandbox"
  write_fake_cargo "$sandbox/fake-bin"

  PATH="$sandbox/fake-bin:/usr/bin:/bin" \
    BASH_ENV=/dev/null \
    HARNESS_CARGO_BIN="$sandbox/fake-bin/cargo" \
    CARGO_TARGET_DIR="$sandbox/build-target" \
    CARGO_BUILD_JOBS="${#HARNESS_RELEASE_ALL_BUILD_LEAVES[@]}" \
    FAKE_CARGO_EVENTS="$build_events" \
    HARNESS_RELEASE_HOST_OS=Darwin \
    "$ROOT/scripts/cargo-local.sh" --with-group-lease \
    "$ROOT/scripts/build-release-set.sh" all >/dev/null

  assert_not_contains "leaf=systemd" "$(command cat "$build_events")" || ok=0
  assert_not_contains "-p harness-systemd" "$(command cat "$build_events")" || ok=0

  write_fake_release_set "$sandbox/target" 47.0.0
  run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null
  old_target="$(command readlink "$sandbox/install-root/current")"
  assert_contains "harness-systemd 47.0.0" \
    "$("$sandbox/bin/harness-systemd" --version)" || ok=0

  write_fake_release_set "$sandbox/target" 48.0.0
  command rm -f "$sandbox/target/release/harness-systemd"
  HARNESS_RELEASE_HOST_OS=Darwin \
    HARNESS_INSTALL_TEST_FAIL_AFTER_ACTIVATION=1 \
    run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all \
    >/dev/null 2>&1 || status=$?
  failed_target="$(command readlink "$sandbox/install-root/current")"
  if (( status != 97 )); then
    fail "expected injected Darwin activation failure status 97, got $status"
    ok=0
  fi
  if [[ "$failed_target" != "$old_target" ]]; then
    fail "failed Darwin install did not restore the previous current target"
    ok=0
  fi
  assert_contains "harness-systemd 47.0.0" \
    "$("$sandbox/bin/harness-systemd" --version)" || ok=0

  HARNESS_RELEASE_HOST_OS=Darwin \
    run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null
  active_target="$(command readlink "$sandbox/install-root/current")"
  for name in "${HARNESS_BINARIES[@]}"; do
    [[ "$name" != harness-systemd ]] || continue
    [[ -L "$sandbox/bin/$name" && -x "$sandbox/bin/$name" ]] || {
      fail "Darwin install is missing managed entrypoint $name"
      ok=0
    }
  done
  [[ ! -e "$sandbox/bin/harness-systemd" && ! -L "$sandbox/bin/harness-systemd" ]] || {
    fail "Darwin install retained the managed harness-systemd entrypoint"
    ok=0
  }
  [[ ! -e "$sandbox/install-root/$active_target/bin/harness-systemd" ]] || {
    fail "Darwin release candidate contains harness-systemd"
    ok=0
  }
  [[ -x "$sandbox/install-root/$old_target/bin/harness-systemd" ]] || {
    fail "Darwin migration mutated the retained Linux rollback release"
    ok=0
  }
  if (( ok )); then pass; fi
}

scenario_missing_build_artifact_aborts_publication() {
  start_test "missing build artifact aborts publication and activation"
  local sandbox="$SANDBOX/build-missing-artifact"
  local events="$sandbox/events" status=0 name before after ok=1
  command mkdir -p "$sandbox"
  write_fake_cargo "$sandbox/fake-bin"
  write_fake_release_set "$sandbox/target" 47.0.0

  PATH="$sandbox/fake-bin:/usr/bin:/bin" \
    BASH_ENV=/dev/null \
    HOME="$sandbox/home" \
    HARNESS_CARGO_BIN="$sandbox/fake-bin/cargo" \
    CARGO_TARGET_DIR="$sandbox/target" \
    CARGO_BUILD_JOBS=3 \
    FAKE_CARGO_EVENTS="$events" \
    FAKE_CARGO_OMIT_ARTIFACT_LEAF=mcp \
    HARNESS_INSTALL_ROOT="$sandbox/install-root" \
    HARNESS_INSTALL_BINARY_DIR="$sandbox/bin" \
    AFF_INSTALL_BINARY_DIR="$sandbox/aff-bin" \
    HARNESS_INSTALL_SKIP_CODESIGN=1 \
    AFF_INSTALL_SKIP_CODESIGN=1 \
    HARNESS_INSTALL_CLEANUP_CLI_DAEMON=0 \
    HARNESS_INSTALL_LEGACY_CONFIG_ROOT="$sandbox/project" \
    "$ROOT/scripts/build-and-install-release-set.sh" all \
    >"$sandbox/output" 2>&1 || status=$?

  if (( status == 0 )); then
    fail "expected missing build artifact to fail the release pipeline"
    ok=0
  fi
  assert_contains "release build did not produce executable" \
    "$(command cat "$sandbox/output")" || ok=0
  for name in "${RELEASE_BINARIES[@]}"; do
    before="$name 47.0.0"
    after="$("$sandbox/target/release/$name" --version 2>/dev/null || true)"
    if [[ "$after" != "$before" ]]; then
      fail "prior canonical artifact changed for $name"
      ok=0
    fi
  done
  if [[ -e "$sandbox/install-root/current" ]]; then
    fail "installer ran after build publication failed"
    ok=0
  fi
  if find "$sandbox/target/.release-build/publish" -mindepth 1 -print -quit \
    2>/dev/null | command grep -q .; then
    fail "failed publication left staging debris"
    ok=0
  fi
  if (( ok )); then pass; fi
}

scenario_build_group_cancels_siblings() {
  start_test "release build group cancels siblings on first failure"
  local sandbox="$SANDBOX/build-failure"
  local events="$sandbox/events"
  local status=0
  command mkdir -p "$sandbox"
  write_fake_cargo "$sandbox/fake-bin"

  PATH="$sandbox/fake-bin:/usr/bin:/bin" \
    BASH_ENV=/dev/null \
    HARNESS_CARGO_BIN="$sandbox/fake-bin/cargo" \
    CARGO_TARGET_DIR="$sandbox/target" \
    CARGO_BUILD_JOBS="${#HARNESS_RELEASE_ALL_BUILD_LEAVES[@]}" \
    CODEX_SESSION_ID="release-failure-test-$$" \
    FAKE_CARGO_EVENTS="$events" \
    FAKE_CARGO_FAIL_LEAF=codex \
    FAKE_CARGO_SLEEP=8 \
    "$ROOT/scripts/cargo-local.sh" --with-group-lease \
    "$ROOT/scripts/build-release-set.sh" all >/dev/null 2>&1 || status=$?

  local output leaf started_pid
  output="$(command cat "$events")"
  local ok=1
  if (( status != 41 )); then
    fail "expected failure status 41, got $status"
    ok=0
  fi
  assert_contains "fail leaf=codex" "$output" || ok=0
  assert_contains "term leaf=" "$output" || ok=0
  for leaf in "${HARNESS_RELEASE_ALL_BUILD_LEAVES[@]}"; do
    [[ "$leaf" != codex ]] || continue
    started_pid="$(command sed -n \
      "s/^start leaf=$leaf .* pid=\([0-9][0-9]*\) .*/\1/p" "$events")"
    if [[ -z "$started_pid" ]]; then
      fail "missing started PID for sibling leaf $leaf"
      ok=0
    elif command kill -0 "$started_pid" 2>/dev/null; then
      fail "sibling leaf survived cancellation: $leaf (pid $started_pid)"
      ok=0
    fi
  done
  [[ -n "$(find "$sandbox/target/.release-build/logs" -name codex.log -print -quit)" ]] || {
    fail "missing retained Codex log"
    ok=0
  }
  if (( ok )); then pass; fi
}

scenario_unexpected_coordinator_exit_cleans_children_and_lock() {
  start_test "unexpected release coordinator exit cleans children and pipeline lock"
  local sandbox="$SANDBOX/build-exit-cleanup"
  local events="$sandbox/events" status=0
  command mkdir -p "$sandbox"
  write_fake_cargo "$sandbox/fake-bin"

  PATH="$sandbox/fake-bin:/usr/bin:/bin" \
    BASH_ENV=/dev/null \
    HARNESS_CARGO_BIN="$sandbox/fake-bin/cargo" \
    CARGO_TARGET_DIR="$sandbox/target" \
    CARGO_BUILD_JOBS=2 \
    CODEX_SESSION_ID="release-exit-test-$$" \
    FAKE_CARGO_EVENTS="$events" \
    FAKE_CARGO_SLEEP=8 \
    HARNESS_RELEASE_BUILD_TEST_EXIT_AFTER_STARTS=2 \
    HARNESS_RELEASE_BUILD_TEST_EXIT_DELAY_SECONDS=1.5 \
    "$ROOT/scripts/build-release-set.sh" all >/dev/null 2>&1 || status=$?

  local output started_pid ok=1
  output="$(command cat "$events" 2>/dev/null || true)"
  if (( status != 91 )); then
    fail "expected injected status 91, got $status"
    ok=0
  fi
  assert_contains "start leaf=" "$output" || ok=0
  while read -r started_pid; do
    [[ -n "$started_pid" ]] || continue
    if command kill -0 "$started_pid" 2>/dev/null; then
      fail "build child $started_pid survived coordinator exit"
      ok=0
    fi
  done < <(command sed -n 's/.* pid=\([0-9][0-9]*\) .*/\1/p' <<<"$output")
  [[ ! -e "$sandbox/target/.release-pipeline.lock" ]] || {
    fail "pipeline lock survived coordinator exit"
    ok=0
  }
  if (( ok )); then pass; fi
}

scenario_build_group_queues_below_leaf_count() {
  start_test "release build group queues leaves above the shared job cap"
  local sandbox="$SANDBOX/build-queue"
  local events="$sandbox/events"
  local trace="$sandbox/trace"
  command mkdir -p "$sandbox"
  write_fake_cargo "$sandbox/fake-bin"

  PATH="$sandbox/fake-bin:/usr/bin:/bin" \
    BASH_ENV=/dev/null \
    HARNESS_CARGO_BIN="$sandbox/fake-bin/cargo" \
    CARGO_TARGET_DIR="$sandbox/target" \
    CARGO_BUILD_JOBS=2 \
    CODEX_SESSION_ID="release-queue-test-$$" \
    FAKE_CARGO_EVENTS="$events" \
    HARNESS_RELEASE_BUILD_TRACE="$trace" \
    "$ROOT/scripts/cargo-local.sh" --with-group-lease \
    "$ROOT/scripts/build-release-set.sh" all >/dev/null

  local bridge_line first_finish_line starts_before_finish
  bridge_line="$(command grep -n 'start leaf=bridge' "$trace" | command cut -d: -f1)"
  first_finish_line="$(command grep -n 'finish leaf=' "$trace" | command head -1 | command cut -d: -f1)"
  starts_before_finish="$(command sed -n "1,${first_finish_line}p" "$trace" \
    | command grep -c 'start leaf=')"
  local ok=1
  if (( starts_before_finish != 2 )); then
    fail "expected two initial leaves, got $starts_before_finish"
    ok=0
  fi
  if (( bridge_line <= first_finish_line )); then
    fail "bridge started before a slot was released"
    ok=0
  fi
  assert_contains "start leaf=bridge jobs=1" "$(command cat "$trace")" || ok=0
  assert_contains "start leaf=openrouter jobs=1" "$(command cat "$trace")" || ok=0
  if (( ok )); then pass; fi
}

scenario_overlapping_build_groups_keep_separate_logs() {
  start_test "overlapping release groups serialize artifacts and keep scoped logs"
  local sandbox="$SANDBOX/build-overlap"
  local first_status=0 second_status=0 directory_count log_count overlapped=0
  local first_targets second_targets
  command mkdir -p "$sandbox"
  write_fake_cargo "$sandbox/fake-bin"

  PATH="$sandbox/fake-bin:/usr/bin:/bin" \
    BASH_ENV=/dev/null \
    HARNESS_CARGO_BIN="$sandbox/fake-bin/cargo" \
    CARGO_TARGET_DIR="$sandbox/target" \
    CARGO_BUILD_JOBS=3 \
    FAKE_CARGO_EVENTS="$sandbox/first-events" \
    FAKE_CARGO_SLEEP=0.4 \
    HARNESS_RELEASE_BUILD_LOG_DIR="$sandbox/logs" \
    "$ROOT/scripts/build-release-set.sh" all >/dev/null &
  first_pid=$!
  for _ in {1..80}; do
    command grep -q 'start leaf=' "$sandbox/first-events" 2>/dev/null && break
    sleep 0.025
  done
  PATH="$sandbox/fake-bin:/usr/bin:/bin" \
    BASH_ENV=/dev/null \
    HARNESS_CARGO_BIN="$sandbox/fake-bin/cargo" \
    CARGO_TARGET_DIR="$sandbox/target" \
    CARGO_BUILD_JOBS=3 \
    FAKE_CARGO_EVENTS="$sandbox/second-events" \
    FAKE_CARGO_SLEEP=0.4 \
    HARNESS_RELEASE_BUILD_LOG_DIR="$sandbox/logs" \
    "$ROOT/scripts/build-release-set.sh" all >/dev/null &
  second_pid=$!
  sleep 0.15
  if command grep -q 'start leaf=' "$sandbox/second-events" 2>/dev/null; then
    overlapped=1
  fi
  wait "$first_pid" || first_status=$?
  wait "$second_pid" || second_status=$?

  directory_count="$(find "$sandbox/logs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  log_count="$(find "$sandbox/logs" -type f -name '*.log' | wc -l | tr -d ' ')"
  local ok=1
  if (( first_status != 0 || second_status != 0 )); then
    fail "overlapping groups failed (first=$first_status second=$second_status)"
    ok=0
  fi
  if (( overlapped != 0 )); then
    fail "second release group wrote artifacts while the first group was active"
    ok=0
  fi
  first_targets="$(command sed -n 's/.* target_dir=\([^ ]*\) .*/\1/p' \
    "$sandbox/first-events" | command sort -u)"
  second_targets="$(command sed -n 's/.* target_dir=\([^ ]*\) .*/\1/p' \
    "$sandbox/second-events" | command sort -u)"
  if [[ "$first_targets" != "$second_targets" ]]; then
    fail "release rerun did not reuse stable per-leaf targets"
    ok=0
  fi
  local expected_log_count=$((2 * ${#RELEASE_BINARIES[@]}))
  if (( directory_count != 2 || log_count != expected_log_count )); then
    fail "expected two complete leaf-log sets, got $directory_count directories and $log_count logs"
    ok=0
  fi
  if (( ok )); then pass; fi
}

scenario_pipeline_lock_spans_build_and_install() {
  start_test "release pipeline lock spans grouped build through activation"
  local sandbox="$SANDBOX/pipeline-lock"
  local wrapper_status=0 contender_status=0 overlapped=0
  command mkdir -p "$sandbox"
  write_fake_cargo "$sandbox/fake-bin"
  write_fake_release_set "$sandbox/target" 48.0.0

  PATH="$sandbox/fake-bin:/usr/bin:/bin" \
    BASH_ENV=/dev/null \
    HOME="$sandbox/home" \
    HARNESS_CARGO_BIN="$sandbox/fake-bin/cargo" \
    CARGO_TARGET_DIR="$sandbox/target" \
    CARGO_BUILD_JOBS=3 \
    FAKE_CARGO_EVENTS="$sandbox/wrapper-events" \
    FAKE_CARGO_SLEEP=0.02 \
    HARNESS_INSTALL_ROOT="$sandbox/install-root" \
    HARNESS_INSTALL_BINARY_DIR="$sandbox/bin" \
    AFF_INSTALL_BINARY_DIR="$sandbox/aff-bin" \
    HARNESS_INSTALL_SKIP_CODESIGN=1 \
    AFF_INSTALL_SKIP_CODESIGN=1 \
    HARNESS_INSTALL_CLEANUP_CLI_DAEMON=0 \
    HARNESS_INSTALL_LEGACY_CONFIG_ROOT="$sandbox/project" \
    HARNESS_INSTALL_TEST_HOLD_LOCK_SECONDS=0.5 \
    "$ROOT/scripts/build-and-install-release-set.sh" all \
    >"$sandbox/wrapper.log" 2>&1 &
  wrapper_pid=$!
  for _ in {1..120}; do
    [[ -f "$sandbox/install-root/.install.lock/owner" ]] && break
    sleep 0.025
  done

  PATH="$sandbox/fake-bin:/usr/bin:/bin" \
    BASH_ENV=/dev/null \
    HARNESS_CARGO_BIN="$sandbox/fake-bin/cargo" \
    CARGO_TARGET_DIR="$sandbox/target" \
    CARGO_BUILD_JOBS=2 \
    FAKE_CARGO_EVENTS="$sandbox/contender-events" \
    FAKE_CARGO_SLEEP=0.02 \
    "$ROOT/scripts/build-release-set.sh" harness >/dev/null &
  contender_pid=$!
  sleep 0.15
  if command grep -q 'start leaf=' "$sandbox/contender-events" 2>/dev/null; then
    overlapped=1
  fi
  wait "$wrapper_pid" || wrapper_status=$?
  wait "$contender_pid" || contender_status=$?

  local ok=1
  if (( wrapper_status != 0 || contender_status != 0 )); then
    fail "pipeline participants failed (wrapper=$wrapper_status contender=$contender_status)"
    ok=0
  fi
  if (( overlapped != 0 )); then
    fail "contending build started before installer activation released the pipeline"
    ok=0
  fi
  [[ ! -e "$sandbox/target/.release-pipeline.lock" ]] || {
    fail "pipeline lock survived completed build/install flow"
    ok=0
  }
  if (( ok )); then pass; fi
}

scenario_atomic_install_activates_all_binaries() {
  start_test "atomic installer activates the complete release inventory"
  local sandbox="$SANDBOX/atomic"
  write_fake_release_set "$sandbox/target" 48.0.0
  run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null

  local ok=1 name path
  [[ -L "$sandbox/install-root/current" ]] || {
    fail "current is not a symlink"
    ok=0
  }
  for name in "${HARNESS_BINARIES[@]}"; do
    path="$sandbox/bin/$name"
    [[ -L "$path" && -x "$path" ]] || {
      fail "missing managed entrypoint $path"
      ok=0
    }
  done
  [[ -L "$sandbox/aff-bin/aff" && -x "$sandbox/aff-bin/aff" ]] || {
    fail "missing managed aff entrypoint"
    ok=0
  }
  assert_contains "harness 48.0.0" "$("$sandbox/bin/harness" --version)" || ok=0
  assert_contains "aff 48.0.0" "$("$sandbox/aff-bin/aff" --version)" || ok=0
  if (( ok )); then pass; fi
}

scenario_successful_installs_prune_inactive_release_sets() {
  start_test "successful installs retain a bounded rollback window"
  local sandbox="$SANDBOX/release-retention"
  local active_target previous_target directory_count version

  for version in 47.0.0 48.0.0 49.0.0; do
    write_fake_release_set "$sandbox/target" "$version"
    HARNESS_INSTALL_RETAIN_RELEASE_SETS=2 \
      run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null
  done
  previous_target="$(command readlink "$sandbox/install-root/current")"

  write_fake_release_set "$sandbox/target" 50.0.0
  HARNESS_INSTALL_RETAIN_RELEASE_SETS=2 \
    run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null
  active_target="$(command readlink "$sandbox/install-root/current")"
  directory_count="$(find "$sandbox/install-root" -mindepth 1 -maxdepth 1 \
    -type d ! -name '.*' | wc -l | tr -d ' ')"

  local ok=1
  if (( directory_count != 2 )); then
    fail "expected bounded release retention, found $directory_count directories"
    ok=0
  fi
  [[ -d "$sandbox/install-root/$active_target/bin" ]] || {
    fail "active release set was pruned"
    ok=0
  }
  [[ -d "$sandbox/install-root/$previous_target/bin" ]] || {
    fail "rollback release set was pruned"
    ok=0
  }
  assert_contains "harness 50.0.0" "$("$sandbox/bin/harness" --version)" || ok=0
  if (( ok )); then pass; fi
}

scenario_live_worker_release_survives_retention() {
  start_test "live retired worker release survives bounded pruning"
  local sandbox="$SANDBOX/release-retention-live-worker"
  local live_target live_worker live_pid inactive_target rollback_target active_target
  local directory_count version

  write_fake_release_set "$sandbox/target" 47.0.0
  HARNESS_INSTALL_RETAIN_RELEASE_SETS=2 \
    run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null
  live_target="$(command readlink "$sandbox/install-root/current")"
  live_worker="$sandbox/install-root/$live_target/bin/harness-daemon"
  command rm -f "$live_worker"
  command ln -s /bin/sleep "$live_worker"
  "$live_worker" 120 &
  live_pid=$!
  TEST_WORKER_PIDS+=("$live_pid")

  for version in 48.0.0 49.0.0; do
    write_fake_release_set "$sandbox/target" "$version"
    HARNESS_INSTALL_RETAIN_RELEASE_SETS=2 \
      run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null
    if [[ "$version" == 48.0.0 ]]; then
      inactive_target="$(command readlink "$sandbox/install-root/current")"
    fi
  done
  rollback_target="$(command readlink "$sandbox/install-root/current")"

  write_fake_release_set "$sandbox/target" 50.0.0
  HARNESS_INSTALL_RETAIN_RELEASE_SETS=2 \
    run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null
  active_target="$(command readlink "$sandbox/install-root/current")"
  directory_count="$(find "$sandbox/install-root" -mindepth 1 -maxdepth 1 \
    -type d ! -name '.*' | wc -l | tr -d ' ')"

  local ok=1
  command kill -0 "$live_pid" 2>/dev/null || {
    fail "retired worker stopped before retention completed"
    ok=0
  }
  [[ -d "$sandbox/install-root/$live_target/bin" ]] || {
    fail "release backing a live worker was pruned"
    ok=0
  }
  [[ ! -e "$sandbox/install-root/$inactive_target" ]] || {
    fail "inactive release survived beyond the retention window"
    ok=0
  }
  [[ -d "$sandbox/install-root/$rollback_target/bin" ]] || {
    fail "rollback release set was pruned"
    ok=0
  }
  [[ -d "$sandbox/install-root/$active_target/bin" ]] || {
    fail "active release set was pruned"
    ok=0
  }
  if (( directory_count != 3 )); then
    fail "expected active, rollback, and live release directories, found $directory_count"
    ok=0
  fi
  command kill "$live_pid" 2>/dev/null || true
  wait "$live_pid" 2>/dev/null || true
  if (( ok )); then pass; fi
}

scenario_failed_install_keeps_rollback_target() {
  start_test "failed activation keeps the rollback target under retention"
  local sandbox="$SANDBOX/release-retention-rollback"
  local rollback_target current_target output status=0
  write_fake_release_set "$sandbox/target" 47.0.0
  HARNESS_INSTALL_RETAIN_RELEASE_SETS=2 \
    run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null
  rollback_target="$(command readlink "$sandbox/install-root/current")"

  write_fake_release_set "$sandbox/target" 48.0.0
  output="$(HARNESS_INSTALL_RETAIN_RELEASE_SETS=2 \
    HARNESS_INSTALL_TEST_FAIL_AFTER_ACTIVATION=1 \
    run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all 2>&1)" \
    || status=$?
  current_target="$(command readlink "$sandbox/install-root/current")"

  local ok=1
  if (( status != 97 )); then
    fail "expected injected status 97, got $status: $output"
    ok=0
  fi
  if [[ "$current_target" != "$rollback_target" ]]; then
    fail "current did not return to its rollback target"
    ok=0
  fi
  [[ -d "$sandbox/install-root/$rollback_target/bin" ]] || {
    fail "failed install pruned its rollback target"
    ok=0
  }
  assert_contains "harness 47.0.0" "$("$sandbox/bin/harness" --version)" || ok=0
  if (( ok )); then pass; fi
}

scenario_adapter_probe_requires_exact_identity() {
  start_test "adapter probe must report its exact configured identity"
  local sandbox="$SANDBOX/adapter-identity" status=0 output
  write_fake_release_set "$sandbox/target" 48.0.0
  command cat >"$sandbox/target/release/harness-codex-acp" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--probe" ]]; then
  printf 'harness-openrouter-agent\n'
  exit 0
fi
exit 0
EOF
  command chmod +x "$sandbox/target/release/harness-codex-acp"

  output="$(run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all 2>&1)" \
    || status=$?
  local ok=1
  if (( status == 0 )); then
    fail "installer accepted the wrong adapter identity"
    ok=0
  fi
  assert_contains "release artifact failed its identity probe" "$output" || ok=0
  [[ ! -e "$sandbox/install-root/current" ]] || {
    fail "adapter identity failure activated a candidate"
    ok=0
  }
  if (( ok )); then pass; fi
}

scenario_first_install_activates_before_entrypoints() {
  start_test "first install activates the candidate before publishing entrypoints"
  local sandbox="$SANDBOX/activation-order" installer_pid status=0 name
  write_fake_release_set "$sandbox/target" 48.0.0

  HARNESS_INSTALL_TEST_HOLD_AFTER_ACTIVATION_SECONDS=0.5 \
    run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all \
    >"$sandbox/install.log" 2>&1 &
  installer_pid=$!
  for _ in {1..400}; do
    [[ -L "$sandbox/install-root/current" ]] && break
    sleep 0.025
  done

  local ok=1
  [[ -L "$sandbox/install-root/current" ]] || {
    fail "candidate was not activated during the publication hold"
    ok=0
  }
  for name in "${HARNESS_BINARIES[@]}"; do
    [[ ! -e "$sandbox/bin/$name" && ! -L "$sandbox/bin/$name" ]] || {
      fail "entrypoint was published before activation completed: $name"
      ok=0
    }
  done
  [[ ! -e "$sandbox/aff-bin/aff" && ! -L "$sandbox/aff-bin/aff" ]] || {
    fail "aff entrypoint was published before activation completed"
    ok=0
  }

  wait "$installer_pid" || status=$?
  if (( status != 0 )); then
    fail "installer failed after activation-order check: $status"
    ok=0
  fi
  [[ -x "$sandbox/bin/harness" && -x "$sandbox/aff-bin/aff" ]] || {
    fail "entrypoints were not published after activation"
    ok=0
  }
  if (( ok )); then pass; fi
}

scenario_post_activation_failure_rolls_back() {
  start_test "post-activation failure restores the previous set"
  local sandbox="$SANDBOX/rollback"
  local old_current output status=0
  write_fake_release_set "$sandbox/target" 47.0.0
  run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null
  old_current="$(command readlink "$sandbox/install-root/current")"
  write_fake_release_set "$sandbox/target" 48.0.0

  output="$(HARNESS_INSTALL_TEST_FAIL_AFTER_ACTIVATION=1 \
    run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all 2>&1)" \
    || status=$?

  local ok=1
  if (( status != 97 )); then
    fail "expected injected status 97, got $status: $output"
    ok=0
  fi
  if [[ "$(command readlink "$sandbox/install-root/current")" != "$old_current" ]]; then
    fail "current did not roll back"
    ok=0
  fi
  assert_contains "harness 47.0.0" "$("$sandbox/bin/harness" --version)" || ok=0
  if (( ok )); then pass; fi
}

scenario_legacy_binaries_are_normalized_before_activation() {
  start_test "legacy direct binaries are preserved behind current before activation"
  local sandbox="$SANDBOX/legacy"
  local legacy_dir
  write_fake_release_set "$sandbox/target" 47.0.0
  command mkdir -p "$sandbox/bin" "$sandbox/aff-bin"
  command cp "$sandbox/target/release/harness" "$sandbox/bin/harness"
  command cp "$sandbox/target/release/aff" "$sandbox/aff-bin/aff"
  write_fake_release_set "$sandbox/target" 48.0.0

  run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null
  legacy_dir="$(find "$sandbox/install-root" -maxdepth 1 -type d -name 'legacy-*' | command head -1)"

  local ok=1
  [[ -n "$legacy_dir" ]] || {
    fail "missing normalized legacy bundle"
    ok=0
  }
  if [[ -n "$legacy_dir" ]]; then
    assert_contains "harness 47.0.0" "$("$legacy_dir/bin/harness" --version)" || ok=0
  fi
  [[ -L "$sandbox/bin/harness" && -L "$sandbox/aff-bin/aff" ]] || {
    fail "legacy entrypoints were not converted to managed links"
    ok=0
  }
  assert_contains "harness 48.0.0" "$("$sandbox/bin/harness" --version)" || ok=0
  if (( ok )); then pass; fi
}

scenario_legacy_adapter_probes_are_normalized_before_activation() {
  start_test "legacy silent adapter probes are normalized before activation"
  local sandbox="$SANDBOX/legacy-adapters"
  local legacy_dir name output
  local -a names=(harness-codex-acp harness-openrouter-agent)
  write_fake_release_set "$sandbox/target" 48.0.0
  write_fake_codesign "$sandbox/fake-bin"
  command mkdir -p "$sandbox/bin"

  for name in "${names[@]}"; do
    command cat >"$sandbox/bin/$name" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--probe" ]]; then
  exit 0
fi
exit 2
EOF
    command chmod 555 "$sandbox/bin/$name"
  done

  RUN_INSTALLER_PATH="$sandbox/fake-bin:/usr/bin:/bin" \
    run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null
  legacy_dir="$(find "$sandbox/install-root" -maxdepth 1 -type d -name 'legacy-*' | command head -1)"

  local ok=1
  [[ -n "$legacy_dir" ]] || {
    fail "missing normalized legacy adapter bundle"
    ok=0
  }
  for name in "${names[@]}"; do
    if [[ -n "$legacy_dir" ]]; then
      output="$("$legacy_dir/bin/$name" --probe)"
      [[ -z "$output" ]] || {
        fail "legacy adapter probe unexpectedly reported an identity: $name"
        ok=0
      }
    fi
    [[ -L "$sandbox/bin/$name" ]] || {
      fail "legacy adapter entrypoint was not converted to a managed link: $name"
      ok=0
    }
    assert_contains "$name" "$("$sandbox/bin/$name" --probe)" || ok=0
  done
  if (( ok )); then pass; fi
}

scenario_untrusted_legacy_adapter_probe_is_preserved() {
  start_test "untrusted silent adapter probe is preserved"
  local sandbox="$SANDBOX/untrusted-legacy-adapter" status=0 output before after
  local name=harness-codex-acp
  write_fake_release_set "$sandbox/target" 48.0.0
  write_fake_codesign "$sandbox/fake-bin"
  command mkdir -p "$sandbox/bin"
  command cat >"$sandbox/bin/$name" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--probe" ]]; then
  exit 0
fi
exit 2
EOF
  command chmod 555 "$sandbox/bin/$name"
  before="$(command shasum -a 256 "$sandbox/bin/$name")"

  output="$(RUN_INSTALLER_PATH="$sandbox/fake-bin:/usr/bin:/bin" \
    FAKE_CODESIGN_FAIL_REQUIREMENT_NAME="$name" \
    run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all 2>&1)" \
    || status=$?
  after="$(command shasum -a 256 "$sandbox/bin/$name")"

  local ok=1
  if (( status == 0 )); then
    fail "installer accepted an untrusted legacy adapter"
    ok=0
  fi
  assert_contains "refusing to replace non-Harness binary" "$output" || ok=0
  if [[ "$after" != "$before" || -L "$sandbox/bin/$name" ]]; then
    fail "untrusted legacy adapter was modified"
    ok=0
  fi
  [[ ! -e "$sandbox/install-root/current" ]] || {
    fail "untrusted legacy adapter activated a candidate"
    ok=0
  }
  if (( ok )); then pass; fi
}

scenario_install_lock_serializes_overlapping_activation() {
  start_test "install lock serializes overlapping activation"
  local sandbox="$SANDBOX/lock"
  local first_status=0 second_status=0
  write_fake_release_set "$sandbox/target" 48.0.0

  HARNESS_INSTALL_TEST_HOLD_LOCK_SECONDS=0.4 \
    run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all \
    >"$sandbox/first.log" 2>&1 &
  first_pid=$!
  for _ in {1..40}; do
    [[ -f "$sandbox/install-root/.install.lock/owner" ]] && break
    sleep 0.05
  done
  run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all \
    >"$sandbox/second.log" 2>&1 || second_status=$?
  wait "$first_pid" || first_status=$?

  local ok=1
  if (( first_status != 0 || second_status != 0 )); then
    fail "overlapping installs failed (first=$first_status second=$second_status)"
    ok=0
  fi
  [[ ! -e "$sandbox/install-root/.install.lock" ]] || {
    fail "install lock was not released"
    ok=0
  }
  assert_contains "harness 48.0.0" "$("$sandbox/bin/harness" --version)" || ok=0
  if (( ok )); then pass; fi
}

scenario_non_owned_entrypoint_is_preserved() {
  start_test "installer refuses a non-Harness entrypoint"
  local sandbox="$SANDBOX/non-owned"
  local status=0 output
  write_fake_release_set "$sandbox/target" 48.0.0
  command mkdir -p "$sandbox/bin"
  command cat >"$sandbox/bin/harness" <<'EOF'
#!/usr/bin/env bash
printf 'not-harness 1.0.0\n'
EOF
  command chmod +x "$sandbox/bin/harness"

  output="$(run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all 2>&1)" \
    || status=$?
  local ok=1
  if (( status == 0 )); then
    fail "expected non-owned entrypoint refusal"
    ok=0
  fi
  assert_contains "refusing to replace non-Harness binary" "$output" || ok=0
  assert_contains "not-harness 1.0.0" "$("$sandbox/bin/harness")" || ok=0
  if (( ok )); then pass; fi
}

scenario_failed_first_activation_removes_current_and_links() {
  start_test "failed first activation leaves no current, entrypoints, or debris"
  local sandbox="$SANDBOX/first-rollback" status=0 output name
  write_fake_release_set "$sandbox/target" 48.0.0
  output="$(HARNESS_INSTALL_TEST_FAIL_AFTER_ACTIVATION=1 \
    run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all 2>&1)" \
    || status=$?

  local ok=1
  if (( status != 97 )); then
    fail "expected injected status 97, got $status: $output"
    ok=0
  fi
  [[ ! -e "$sandbox/install-root/current" && ! -L "$sandbox/install-root/current" ]] || {
    fail "first-install current pointer survived rollback"
    ok=0
  }
  for name in "${HARNESS_BINARIES[@]}"; do
    [[ ! -e "$sandbox/bin/$name" && ! -L "$sandbox/bin/$name" ]] || {
      fail "first-install entrypoint survived rollback: $name"
      ok=0
    }
  done
  [[ ! -e "$sandbox/aff-bin/aff" && ! -L "$sandbox/aff-bin/aff" ]] || {
    fail "first-install aff entrypoint survived rollback"
    ok=0
  }
  assert_failed_first_install_is_clean "$sandbox" || ok=0
  if (( ok )); then pass; fi
}

scenario_entrypoint_failure_rolls_back_partial_publication() {
  start_test "entrypoint publication failure removes partial links and staging debris"
  local sandbox="$SANDBOX/link-rollback" status=0 output
  write_fake_release_set "$sandbox/target" 48.0.0
  output="$(HARNESS_INSTALL_TEST_FAIL_AFTER_ENTRYPOINTS=2 \
    run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all 2>&1)" \
    || status=$?

  local ok=1
  if (( status != 96 )); then
    fail "expected injected status 96, got $status: $output"
    ok=0
  fi
  assert_failed_first_install_is_clean "$sandbox" || ok=0
  if (( ok )); then pass; fi
}

scenario_staged_link_failure_removes_next_path() {
  start_test "staged-link failure removes the unpublished next path"
  local sandbox="$SANDBOX/staged-link-rollback" status=0 output
  write_fake_release_set "$sandbox/target" 48.0.0
  output="$(HARNESS_INSTALL_TEST_FAIL_WITH_STAGED_LINK=1 \
    run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all 2>&1)" \
    || status=$?

  local ok=1
  if (( status != 94 )); then
    fail "expected staged-link status 94, got $status: $output"
    ok=0
  fi
  assert_failed_first_install_is_clean "$sandbox" || ok=0
  if (( ok )); then pass; fi
}

scenario_failed_legacy_normalization_restores_direct_files() {
  start_test "failed legacy normalization restores direct entrypoint files"
  local sandbox="$SANDBOX/legacy-rollback" status=0 output
  write_fake_release_set "$sandbox/target" 47.0.0
  command mkdir -p "$sandbox/bin" "$sandbox/aff-bin"
  command cp "$sandbox/target/release/harness" "$sandbox/bin/harness"
  command cp "$sandbox/target/release/aff" "$sandbox/aff-bin/aff"
  write_fake_release_set "$sandbox/target" 48.0.0
  output="$(HARNESS_INSTALL_TEST_FAIL_AFTER_ACTIVATION=1 \
    run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all 2>&1)" \
    || status=$?

  local ok=1
  if (( status != 97 )); then
    fail "expected legacy rollback status 97, got $status: $output"
    ok=0
  fi
  [[ ! -L "$sandbox/bin/harness" && ! -L "$sandbox/aff-bin/aff" ]] || {
    fail "legacy rollback did not restore direct files"
    ok=0
  }
  assert_contains "harness 47.0.0" "$("$sandbox/bin/harness" --version)" || ok=0
  assert_contains "aff 47.0.0" "$("$sandbox/aff-bin/aff" --version)" || ok=0
  assert_failed_first_install_is_clean "$sandbox" || ok=0
  if (( ok )); then pass; fi
}

scenario_full_install_drops_unknown_bundle_files() {
  start_test "full install activates the exact configured inventory"
  local sandbox="$SANDBOX/exact-inventory" count
  write_fake_release_set "$sandbox/target" 47.0.0
  run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null
  printf '#!/usr/bin/env bash\nexit 0\n' >"$sandbox/install-root/current/bin/rogue"
  command chmod +x "$sandbox/install-root/current/bin/rogue"
  write_fake_release_set "$sandbox/target" 48.0.0
  run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null
  count="$(find "$sandbox/install-root/current/bin" -mindepth 1 -maxdepth 1 -type f \
    | wc -l | tr -d ' ')"

  local ok=1
  if [[ -e "$sandbox/install-root/current/bin/rogue" ]]; then
    fail "unknown bundle file survived full activation"
    ok=0
  fi
  if (( count != ${#RELEASE_BINARIES[@]} )); then
    fail "expected the configured active binary inventory, got $count entries"
    ok=0
  fi
  if (( ok )); then pass; fi
}

scenario_focused_install_rejects_corrupt_carried_binary() {
  start_test "focused install identity-probes carried binaries"
  local sandbox="$SANDBOX/carried-identity" old_current status=0 output
  write_fake_release_set "$sandbox/target" 47.0.0
  run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null
  old_current="$(readlink "$sandbox/install-root/current")"
  command rm -f "$sandbox/install-root/current/bin/harness"
  printf '#!/usr/bin/env bash\nprintf "foreign 1.0.0\\n"\n' \
    >"$sandbox/install-root/current/bin/harness"
  command chmod +x "$sandbox/install-root/current/bin/harness"
  write_fake_release_set "$sandbox/target" 48.0.0
  output="$(run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" aff 2>&1)" \
    || status=$?

  local ok=1
  if (( status == 0 )); then
    fail "focused aff install accepted corrupt carried harness"
    ok=0
  fi
  assert_contains "candidate harness failed its identity probe" "$output" || ok=0
  if [[ "$(readlink "$sandbox/install-root/current")" != "$old_current" ]]; then
    fail "focused identity failure changed current"
    ok=0
  fi
  assert_contains "aff 47.0.0" "$("$sandbox/aff-bin/aff" --version)" || ok=0
  if (( ok )); then pass; fi
}

scenario_focused_install_verifies_carried_signature() {
  start_test "focused install verifies carried binary signatures"
  local sandbox="$SANDBOX/carried-signature" old_current status=0 output
  write_fake_release_set "$sandbox/target" 47.0.0
  run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null
  old_current="$(readlink "$sandbox/install-root/current")"
  write_fake_release_set "$sandbox/target" 48.0.0
  write_fake_codesign "$sandbox/fake-bin"
  output="$(RUN_INSTALLER_PATH="$sandbox/fake-bin:/usr/bin:/bin" \
    HARNESS_INSTALL_SKIP_CODESIGN=0 AFF_INSTALL_SKIP_CODESIGN=0 \
    FAKE_CODESIGN_FAIL_VERIFY_NAME=harness \
    run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" aff 2>&1)" \
    || status=$?

  local ok=1
  if (( status != 45 )); then
    fail "expected carried signature status 45, got $status: $output"
    ok=0
  fi
  if [[ "$(readlink "$sandbox/install-root/current")" != "$old_current" ]]; then
    fail "carried signature failure changed current"
    ok=0
  fi
  if (( ok )); then pass; fi
}

scenario_same_version_shadow_is_reconciled() {
  start_test "same-version PATH shadow is reconciled to the active entrypoint"
  local sandbox="$SANDBOX/same-version-shadow"
  write_fake_release_set "$sandbox/target" 48.0.0
  command mkdir -p "$sandbox/shadow"
  command cp "$sandbox/target/release/harness" "$sandbox/shadow/harness"
  RUN_INSTALLER_PATH="$sandbox/shadow:/usr/bin:/bin" \
    run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null

  local ok=1
  [[ -L "$sandbox/shadow/harness" ]] || {
    fail "same-version shadow was not replaced by a symlink"
    ok=0
  }
  if [[ "$(readlink "$sandbox/shadow/harness")" != "$sandbox/bin/harness" ]]; then
    fail "same-version shadow does not target the managed entrypoint"
    ok=0
  fi
  if (( ok )); then pass; fi
}

scenario_shadow_failure_restores_original_on_first_install() {
  start_test "shadow reconciliation failure restores the original first-install shadow"
  local sandbox="$SANDBOX/shadow-rollback" status=0 output
  write_fake_release_set "$sandbox/target" 47.0.0
  command mkdir -p "$sandbox/shadow"
  command cp "$sandbox/target/release/harness" "$sandbox/shadow/harness"
  write_fake_release_set "$sandbox/target" 48.0.0
  output="$(RUN_INSTALLER_PATH="$sandbox/shadow:/usr/bin:/bin" \
    HARNESS_INSTALL_TEST_FAIL_AFTER_SHADOWS=1 \
    run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all 2>&1)" \
    || status=$?

  local ok=1
  if (( status != 98 )); then
    fail "expected injected shadow status 98, got $status: $output"
    ok=0
  fi
  [[ ! -L "$sandbox/shadow/harness" ]] || {
    fail "shadow rollback left the managed symlink"
    ok=0
  }
  assert_contains "harness 47.0.0" "$("$sandbox/shadow/harness" --version)" || ok=0
  assert_failed_first_install_is_clean "$sandbox" || ok=0
  if (( ok )); then pass; fi
}

scenario_aff_install_ignores_unrelated_foreign_harness() {
  start_test "focused aff install leaves an unrelated harness entrypoint alone"
  local sandbox="$SANDBOX/focused-isolation"
  write_fake_release_set "$sandbox/target" 48.0.0
  command mkdir -p "$sandbox/bin"
  printf '#!/usr/bin/env bash\nprintf "foreign-harness 9.0.0\\n"\n' \
    >"$sandbox/bin/harness"
  command chmod +x "$sandbox/bin/harness"
  run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" aff >/dev/null

  local ok=1
  assert_contains "foreign-harness 9.0.0" "$("$sandbox/bin/harness")" || ok=0
  assert_contains "aff 48.0.0" "$("$sandbox/aff-bin/aff" --version)" || ok=0
  if (( ok )); then pass; fi
}

scenario_single_leaf_install_carries_the_rest_forward() {
  start_test "single-leaf install rebuilds one binary and carries the rest forward"
  local sandbox="$SANDBOX/single-leaf" name
  write_fake_release_set "$sandbox/target" 47.0.0
  run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null
  write_fake_release_set "$sandbox/target" 48.0.0
  run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" daemon >/dev/null

  local ok=1
  assert_contains "harness-daemon 48.0.0" \
    "$("$sandbox/bin/harness-daemon" --version)" || ok=0
  for name in "${HARNESS_BINARIES[@]}"; do
    [[ "$name" != harness-daemon ]] || continue
    assert_contains "$name 47.0.0" "$("$sandbox/bin/$name" --version)" || ok=0
  done
  assert_contains "aff 47.0.0" "$("$sandbox/aff-bin/aff" --version)" || ok=0
  if (( ok )); then pass; fi
}

scenario_multi_selector_install_updates_only_requested_leaves() {
  start_test "multi-selector install updates only the requested leaves"
  local sandbox="$SANDBOX/multi-selector" name
  write_fake_release_set "$sandbox/target" 47.0.0
  run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null
  write_fake_release_set "$sandbox/target" 48.0.0
  run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" daemon mcp >/dev/null

  local ok=1
  assert_contains "harness-daemon 48.0.0" \
    "$("$sandbox/bin/harness-daemon" --version)" || ok=0
  assert_contains "harness-mcp 48.0.0" "$("$sandbox/bin/harness-mcp" --version)" || ok=0
  for name in "${HARNESS_BINARIES[@]}"; do
    case "$name" in
      harness-daemon|harness-mcp) continue ;;
    esac
    assert_contains "$name 47.0.0" "$("$sandbox/bin/$name" --version)" || ok=0
  done
  if (( ok )); then pass; fi
}

scenario_harness_cli_alias_selects_only_the_cli_leaf() {
  start_test "harness-cli selector updates only the CLI binary, not the whole harness set"
  local sandbox="$SANDBOX/harness-cli-alias" name
  write_fake_release_set "$sandbox/target" 47.0.0
  run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null
  write_fake_release_set "$sandbox/target" 48.0.0
  run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" harness-cli >/dev/null

  local ok=1
  assert_contains "harness 48.0.0" "$("$sandbox/bin/harness" --version)" || ok=0
  for name in "${HARNESS_BINARIES[@]}"; do
    [[ "$name" != harness ]] || continue
    assert_contains "$name 47.0.0" "$("$sandbox/bin/$name" --version)" || ok=0
  done
  if (( ok )); then pass; fi
}

scenario_unknown_selector_is_rejected_cleanly() {
  start_test "an unknown selector is rejected without touching current"
  local sandbox="$SANDBOX/unknown-selector" old_current status=0 output
  write_fake_release_set "$sandbox/target" 47.0.0
  run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all >/dev/null
  old_current="$(readlink "$sandbox/install-root/current")"
  output="$(run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" \
    bogus-selector 2>&1)" || status=$?

  local ok=1
  if (( status == 0 )); then
    fail "unknown selector was accepted"
    ok=0
  fi
  assert_contains "usage:" "$output" || ok=0
  if [[ "$(readlink "$sandbox/install-root/current")" != "$old_current" ]]; then
    fail "rejected selector changed current"
    ok=0
  fi
  if (( ok )); then pass; fi
}

scenario_lock_recovers_ownerless_and_reused_pid_records() {
  start_test "install lock recovers ownerless and PID-reused stale records"
  local ownerless="$SANDBOX/lock-ownerless" reused="$SANDBOX/lock-reused"
  write_fake_release_set "$ownerless/target" 48.0.0
  command mkdir -p "$ownerless/install-root/.install.lock"
  HARNESS_INSTALL_OWNERLESS_LOCK_STALE_SECONDS=0 \
    run_installer "$ownerless" "$ROOT/scripts/install-release-set.sh" all >/dev/null

  write_fake_release_set "$reused/target" 48.0.0
  command mkdir -p "$reused/install-root/.install.lock"
  printf '%s\n' "$$-old-token|not-the-live-process-start" \
    >"$reused/install-root/.install.lock/owner"
  run_installer "$reused" "$ROOT/scripts/install-release-set.sh" all >/dev/null

  local ok=1
  assert_contains "harness 48.0.0" "$("$ownerless/bin/harness" --version)" || ok=0
  assert_contains "harness 48.0.0" "$("$reused/bin/harness" --version)" || ok=0
  if (( ok )); then pass; fi
}

scenario_legacy_detector_is_read_only_and_blocks_activation() {
  start_test "legacy hook and MCP configs block activation without mutation"
  local base="$SANDBOX/legacy-detector" sandbox path before after output status kind
  local ok=1
  for kind in hook mcp; do
    sandbox="$base/$kind"
    write_fake_release_set "$sandbox/target" 48.0.0
    if [[ "$kind" == hook ]]; then
      path="$sandbox/project/.claude/settings.json"
      command mkdir -p "$(dirname -- "$path")"
      printf '{"command":"harness hook tool-guard"}\n' >"$path"
    else
      path="$sandbox/project/.mcp.json"
      command mkdir -p "$(dirname -- "$path")"
      printf '{"mcpServers":{"h":{"command":"harness","args":["mcp","serve"]}}}\n' \
        >"$path"
    fi
    before="$(command cat "$path")"
    status=0
    output="$(run_installer "$sandbox" "$ROOT/scripts/install-release-set.sh" all 2>&1)" \
      || status=$?
    after="$(command cat "$path")"
    if (( status == 0 )); then
      fail "legacy $kind config did not block activation"
      ok=0
    fi
    assert_contains 'mise run setup:bootstrap' "$output" || ok=0
    if [[ "$after" != "$before" ]]; then
      fail "legacy detector mutated $path"
      ok=0
    fi
    [[ ! -e "$sandbox/install-root/current" ]] || {
      fail "legacy $kind detection activated current"
      ok=0
    }
  done
  if (( ok )); then pass; fi
}

run_all() {
  scenario_release_inventory_is_platform_aware
  scenario_darwin_excludes_systemd_and_migrates_managed_link
  scenario_build_group_allocates_one_budget
  scenario_missing_build_artifact_aborts_publication
  scenario_build_group_cancels_siblings
  scenario_unexpected_coordinator_exit_cleans_children_and_lock
  scenario_build_group_queues_below_leaf_count
  scenario_overlapping_build_groups_keep_separate_logs
  scenario_pipeline_lock_spans_build_and_install
  scenario_atomic_install_activates_all_binaries
  scenario_successful_installs_prune_inactive_release_sets
  scenario_live_worker_release_survives_retention
  scenario_failed_install_keeps_rollback_target
  scenario_adapter_probe_requires_exact_identity
  scenario_first_install_activates_before_entrypoints
  scenario_post_activation_failure_rolls_back
  scenario_legacy_binaries_are_normalized_before_activation
  scenario_legacy_adapter_probes_are_normalized_before_activation
  scenario_untrusted_legacy_adapter_probe_is_preserved
  scenario_install_lock_serializes_overlapping_activation
  scenario_non_owned_entrypoint_is_preserved
  scenario_failed_first_activation_removes_current_and_links
  scenario_entrypoint_failure_rolls_back_partial_publication
  scenario_staged_link_failure_removes_next_path
  scenario_failed_legacy_normalization_restores_direct_files
  scenario_full_install_drops_unknown_bundle_files
  scenario_focused_install_rejects_corrupt_carried_binary
  scenario_focused_install_verifies_carried_signature
  scenario_same_version_shadow_is_reconciled
  scenario_shadow_failure_restores_original_on_first_install
  scenario_aff_install_ignores_unrelated_foreign_harness
  scenario_single_leaf_install_carries_the_rest_forward
  scenario_multi_selector_install_updates_only_requested_leaves
  scenario_harness_cli_alias_selects_only_the_cli_leaf
  scenario_unknown_selector_is_rejected_cleanly
  scenario_lock_recovers_ownerless_and_reused_pid_records
  scenario_legacy_detector_is_read_only_and_blocks_activation
}

run_all
printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT" >&2
(( FAIL_COUNT == 0 ))
