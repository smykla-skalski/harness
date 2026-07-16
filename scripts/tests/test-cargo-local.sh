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

scenario_supported_sccache_is_resolved_once() {
  local fake_bin="$SANDBOX/supported-bin"
  local tmpdir="$SANDBOX/supported-tmp"
  local output
  mkdir -p "$fake_bin" "$tmpdir"
  write_fake_sccache "$fake_bin/sccache" "0.16.0"

  output="$(print_cargo_env "$fake_bin" "$fake_bin/sccache" "$tmpdir")"
  if assert_line "SCCACHE_BIN=$fake_bin/sccache" "$output" \
    && assert_line "SCCACHE_VERSION=0.16.0" "$output" \
    && assert_line "SCCACHE_BASEDIRS=$ROOT:$COMMON_REPO_ROOT" "$output" \
    && assert_contains "SCCACHE_SERVER_UDS=$tmpdir/harness-sccache/" "$output" \
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

scenario_supported_sccache_is_resolved_once
scenario_old_explicit_sccache_is_disabled
scenario_failed_lsof_preserves_unknown_sockets
scenario_cache_wrapper_shortens_long_tmpdir

printf 'cargo-local tests: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT" >&2
(( FAIL_COUNT == 0 ))
