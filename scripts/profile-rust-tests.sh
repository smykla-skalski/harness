#!/usr/bin/env bash
set -euo pipefail
unalias -a 2>/dev/null || true

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$ROOT/scripts/lib/common-repo-root.sh"

usage() {
  printf 'usage: %s <compile|unit|integration>\n' "${0##*/}" >&2
}

if (( $# != 1 )); then
  usage
  exit 2
fi

mode="$1"
case "$mode" in
  compile | unit | integration) ;;
  *)
    usage
    exit 2
    ;;
esac

COMMON_REPO_ROOT="$(resolve_common_repo_root "$ROOT")"
PROFILE_ROOT="${HARNESS_RUST_TEST_PROFILE_ROOT:-$COMMON_REPO_ROOT/target/profile-rust-tests}"
run_stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
commit_short="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || printf 'unknown')"
RUN_DIR="$PROFILE_ROOT/runs/$run_stamp-$mode-$commit_short-$$"
NEXTEST_STORE_DIR="$RUN_DIR/nextest"
NEXTEST_TOOL_CONFIG="$RUN_DIR/nextest-store.toml"
if [[ "$mode" == "compile" ]]; then
  CARGO_TARGET_DIR="$RUN_DIR/cargo"
else
  CARGO_TARGET_DIR="$PROFILE_ROOT/cargo"
fi
CARGO_LOCAL_ENV="$RUN_DIR/cargo-local.env"

mkdir -p "$RUN_DIR" "$NEXTEST_STORE_DIR" "$CARGO_TARGET_DIR"

export CARGO_TARGET_DIR
export HARNESS_CARGO_TARGET_DIR="$CARGO_TARGET_DIR"
export CARGO_BUILD_JOBS=1
export HARNESS_CARGO_JOBS=1
export CARGO_INCREMENTAL=0
export NEXTEST_NO_INPUT_HANDLER=1
unset CARGO_BUILD_BUILD_DIR || true

toml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

write_nextest_tool_config() {
  local escaped_store
  escaped_store="$(toml_escape "$NEXTEST_STORE_DIR")"
  printf '[store]\ndir = "%s"\n' "$escaped_store" >"$NEXTEST_TOOL_CONFIG"
}

capture_command_version() {
  local label="$1"
  shift

  printf '%s:\n' "$label"
  if command -v "$1" >/dev/null 2>&1; then
    "$@" 2>&1 || true
  else
    printf 'unavailable\n'
  fi
}

capture_metadata() {
  {
    printf 'mode=%s\n' "$mode"
    printf 'started_at=%s\n' "$run_stamp"
    printf 'repo_root=%s\n' "$ROOT"
    printf 'common_repo_root=%s\n' "$COMMON_REPO_ROOT"
    printf 'profile_root=%s\n' "$PROFILE_ROOT"
    printf 'run_dir=%s\n' "$RUN_DIR"
    printf 'cargo_target_dir=%s\n' "$CARGO_TARGET_DIR"
    printf 'cargo_incremental=%s\n' "$CARGO_INCREMENTAL"
    printf 'cargo_build_jobs=%s\n' "$CARGO_BUILD_JOBS"
    printf 'git_commit=%s\n' "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')"
    printf 'git_branch=%s\n' \
      "$(git -C "$ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'detached')"
    printf 'uname=%s\n' "$(uname -a)"
    printf '\ngit_status:\n'
    git -C "$ROOT" status --short 2>&1 || true
    printf '\n'
    capture_command_version rustc rustc -Vv
    printf '\n'
    capture_command_version cargo cargo -Vv
    printf '\n'
    capture_command_version cargo-nextest cargo nextest --version
    printf '\n'
    capture_command_version sccache sccache --version
    printf '\n'
    capture_command_version mise mise --version
  } >"$RUN_DIR/metadata.txt"
}

capture_cargo_local_env() {
  "$ROOT/scripts/cargo-local.sh" --print-env >"$CARGO_LOCAL_ENV"

  while IFS='=' read -r key value; do
    case "$key" in
      SCCACHE_BIN | SCCACHE_SERVER_UDS | SCCACHE_IDLE_TIMEOUT | SCCACHE_CACHE_SIZE | SCCACHE_BASEDIRS | HARNESS_SCCACHE_TMPDIR)
        if [[ -n "$value" ]]; then
          export "$key=$value"
        fi
        ;;
    esac
  done <"$CARGO_LOCAL_ENV"
}

sccache_binary() {
  local configured

  configured="$(awk -F= '$1 == "SCCACHE_BIN" { print substr($0, index($0, "=") + 1) }' \
    "$CARGO_LOCAL_ENV")"
  if [[ -n "$configured" && -x "$configured" ]]; then
    printf '%s\n' "$configured"
    return 0
  fi

  return 1
}

capture_sccache_stats() {
  local destination="$1"
  local binary temp_dir

  if binary="$(sccache_binary)"; then
    temp_dir="${HARNESS_SCCACHE_TMPDIR:-${TMPDIR:-/tmp}}"
    temp_dir="${temp_dir%/}/"
    {
      TMPDIR="$temp_dir" "$binary" --version
      TMPDIR="$temp_dir" "$binary" --show-stats
    } >"$destination" 2>&1 || printf 'sccache stats unavailable\n' >"$destination"
  else
    printf 'sccache unavailable\n' >"$destination"
  fi
}

copy_cargo_timing() {
  local name="$1"
  local source="$CARGO_TARGET_DIR/cargo-timings/cargo-timing.html"

  if [[ -f "$source" ]]; then
    mkdir -p "$RUN_DIR/cargo-timings"
    cp "$source" "$RUN_DIR/cargo-timings/$name.html"
  fi
}

run_compile_profile() {
  "$ROOT/scripts/cargo-local.sh" test --quiet -p harness --lib \
    --features full-runtime --no-run --timings || return
  copy_cargo_timing unit || return

  "$ROOT/scripts/cargo-local.sh" build --quiet \
    -p harness-daemon -p harness-bridge -p harness-mcp --timings || return
  copy_cargo_timing integration-workers || return

  "$ROOT/scripts/cargo-local.sh" test --quiet -p harness --test integration \
    --features full-runtime --no-run --timings || return
  copy_cargo_timing integration
}

run_nextest() {
  "$ROOT/scripts/cargo-local.sh" nextest run \
    --config-file "$ROOT/.config/nextest.toml" \
    --tool-config-file "profile-rust-tests:$NEXTEST_TOOL_CONFIG" \
    --user-config-file none \
    --profile rust-timing \
    "$@"
}

run_unit_profile() {
  run_nextest -p harness --lib --features full-runtime
}

run_integration_profile() {
  "$ROOT/scripts/cargo-local.sh" build --quiet \
    -p harness-daemon -p harness-bridge -p harness-mcp || return
  run_nextest -p harness --test integration \
    --features full-runtime
}

write_nextest_tool_config
capture_cargo_local_env
capture_metadata
capture_sccache_stats "$RUN_DIR/sccache-before.txt"

printf 'Rust test profile mode: %s\n' "$mode"
printf 'Artifacts: %s\n' "$RUN_DIR"

started_epoch="$(date '+%s')"
set +e
case "$mode" in
  compile) run_compile_profile ;;
  unit) run_unit_profile ;;
  integration) run_integration_profile ;;
esac 2>&1 | tee "$RUN_DIR/run.log"
command_status="${PIPESTATUS[0]}"
set -e
finished_epoch="$(date '+%s')"

capture_sccache_stats "$RUN_DIR/sccache-after.txt"
{
  printf 'mode=%s\n' "$mode"
  printf 'status=%s\n' "$command_status"
  printf 'started_epoch=%s\n' "$started_epoch"
  printf 'finished_epoch=%s\n' "$finished_epoch"
  printf 'elapsed_seconds=%s\n' "$((finished_epoch - started_epoch))"
  printf 'artifacts=%s\n' "$RUN_DIR"
} >"$RUN_DIR/result.txt"

printf 'Result: status=%s elapsed=%ss\n' \
  "$command_status" "$((finished_epoch - started_epoch))"
printf 'Artifacts: %s\n' "$RUN_DIR"

exit "$command_status"
