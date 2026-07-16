#!/usr/bin/env bash
set -euo pipefail
unalias -a 2>/dev/null || true

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=scripts/lib/run-step.sh
source "$ROOT/scripts/lib/run-step.sh"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$ROOT/scripts/lib/common-repo-root.sh"
COMMON_REPO_ROOT="$(resolve_common_repo_root "$ROOT")"
lease_dir="$COMMON_REPO_ROOT/target/.cargo-local/leases"
lease_path=""
active_build_count=1
skip_build_lease="${HARNESS_CARGO_SKIP_LEASE:-0}"

first_nonempty_env() {
  local var_name value
  for var_name in "$@"; do
    value="${!var_name:-}"
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  done
  return 1
}

sanitize_segment() {
  printf '%s' "$1" | tr -cs '[:alnum:]._-' '-'
}

short_hash() {
  local input="$1" digest

  if command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s' "$input" | shasum -a 256)"
    digest="${digest%% *}"
  elif command -v cksum >/dev/null 2>&1; then
    digest="$(printf '%s' "$input" | cksum)"
    digest="${digest//[^[:alnum:]]/}"
  else
    digest="$(sanitize_segment "$input")"
  fi

  printf '%s\n' "${digest:0:16}"
}

sweep_dead_sccache_sockets() {
  local dir="$1"
  local live_sockets sock
  [[ -d "$dir" ]] || return 0
  command -v lsof >/dev/null 2>&1 || return 0

  if ! live_sockets="$(lsof -U -F n 2>/dev/null \
    | awk '/^n\// {print substr($0,2)}' \
    | sort -u)"; then
    return 0
  fi

  for sock in "$dir"/*.sock; do
    [[ -e "$sock" ]] || continue
    if [[ -n "$live_sockets" ]] && grep -qxF "$sock" <<<"$live_sockets"; then
      continue
    fi
    rm -f "$sock"
  done
}

configure_sccache_socket() {
  local socket_root socket_id safe_user

  [[ -n "${SCCACHE_BIN:-}" ]] || return 0

  if [[ -n "${SCCACHE_SERVER_UDS:-}" ]] \
    || [[ -n "${SCCACHE_SERVER_PORT:-}" ]] \
    || [[ -n "${SCCACHE_NO_DAEMON:-}" ]]; then
    return 0
  fi

  socket_root="${TMPDIR:-/tmp}"
  socket_root="${socket_root%/}/harness-sccache"
  if (( ${#socket_root} > 70 )); then
    safe_user="$(sanitize_segment "${USER:-user}")"
    socket_root="/tmp/harness-sccache-$safe_user"
  fi

  if ! mkdir -p "$socket_root"; then
    return 1
  fi

  sweep_dead_sccache_sockets "$socket_root"
  safe_user="${safe_user:-$(sanitize_segment "${USER:-user}")}"
  if [[ "$socket_root" != "/tmp/harness-sccache-$safe_user" ]]; then
    sweep_dead_sccache_sockets "/tmp/harness-sccache-$safe_user"
  fi

  socket_id="$(short_hash "$COMMON_REPO_ROOT:$target_segment")"
  export SCCACHE_SERVER_UDS="$socket_root/$socket_id.sock"
  export SCCACHE_IDLE_TIMEOUT="${SCCACHE_IDLE_TIMEOUT:-1800}"
  export SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-30G}"
}

configure_sccache_tmpdir() {
  local candidate="${HARNESS_SCCACHE_TMPDIR:-${TMPDIR:-/tmp}}"
  candidate="${candidate%/}"

  if (( ${#candidate} > 60 )) || ! tmpdir_is_usable "$candidate"; then
    candidate="/tmp"
  fi
  tmpdir_is_usable "$candidate" || return 1

  export HARNESS_SCCACHE_TMPDIR="$candidate"
}

cargo_bin_usable() {
  local candidate="${1:-}"
  [[ -n "$candidate" ]] || return 1
  command -v "$candidate" >/dev/null 2>&1 || return 1
  "$candidate" -V >/dev/null 2>&1
}

sccache_bin_usable() {
  local candidate="${1:-}"
  [[ -n "$candidate" ]] || return 1
  [[ -x "$candidate" ]] || return 1
  "$candidate" --version >/dev/null 2>&1
}

sccache_version_supported() {
  local version="${1#v}" major minor patch
  version="${version%%[-+]*}"
  IFS=. read -r major minor patch <<<"$version"
  major="${major:-0}"
  minor="${minor:-0}"
  patch="${patch:-0}"

  [[ "$major" =~ ^[0-9]+$ ]] \
    && [[ "$minor" =~ ^[0-9]+$ ]] \
    && [[ "$patch" =~ ^[0-9]+$ ]] \
    && (( major > 0 || minor >= 14 ))
}

resolve_sccache_candidate() {
  local candidate="$1"

  if [[ "$candidate" == */* ]]; then
    [[ -x "$candidate" ]] || return 1
    printf '%s\n' "$candidate"
    return 0
  fi

  command -v "$candidate"
}

resolve_sccache_bin() {
  local requested="${SCCACHE_BIN:-}" candidate resolved output version

  if [[ -n "$requested" ]]; then
    candidate="$requested"
    resolved="$(resolve_sccache_candidate "$candidate" 2>/dev/null || true)"
    if [[ -n "$resolved" ]] && sccache_bin_usable "$resolved"; then
      output="$("$resolved" --version 2>/dev/null)"
      version="${output##* }"
      if sccache_version_supported "$version"; then
        export SCCACHE_BIN="$resolved"
        export SCCACHE_VERSION="$version"
        return 0
      fi
    fi
    export SCCACHE_BIN=""
    unset SCCACHE_VERSION
    return 1
  fi

  for candidate in sccache /opt/homebrew/bin/sccache /usr/local/bin/sccache; do
    resolved="$(resolve_sccache_candidate "$candidate" 2>/dev/null || true)"
    [[ -n "$resolved" ]] || continue
    sccache_bin_usable "$resolved" || continue
    output="$("$resolved" --version 2>/dev/null)"
    version="${output##* }"
    sccache_version_supported "$version" || continue
    export SCCACHE_BIN="$resolved"
    export SCCACHE_VERSION="$version"
    return 0
  done

  export SCCACHE_BIN=""
  unset SCCACHE_VERSION
  return 1
}

tmpdir_is_usable() {
  local candidate probe
  candidate="${1:-}"
  candidate="${candidate%/}"

  if [[ -z "$candidate" ]] || [[ ! -d "$candidate" ]]; then
    return 1
  fi

  probe="$candidate/.harness-tmp-probe-$$"
  if ! touch "$probe" 2>/dev/null; then
    return 1
  fi
  rm -f "$probe"
}

prepare_private_tmpdir() {
  local path="$1"

  if [[ -L "$path" ]]; then
    return 1
  fi
  if [[ -e "$path" ]]; then
    [[ -d "$path" && -O "$path" ]] || return 1
  else
    (umask 077 && mkdir "$path") 2>/dev/null || true
    [[ ! -L "$path" && -d "$path" && -O "$path" ]] || return 1
  fi

  chmod 700 "$path" || return 1
  tmpdir_is_usable "$path"
}

configure_tmpdir() {
  local external_fallback repo_fallback tmpdir_id

  if tmpdir_is_usable "${TMPDIR:-}"; then
    return 0
  fi

  tmpdir_id="$(short_hash "${UID:-${USER:-user}}:$COMMON_REPO_ROOT:$ROOT:$target_segment")"
  external_fallback="/tmp/harness-cargo-$tmpdir_id"
  if tmpdir_is_usable "/tmp"; then
    if ! prepare_private_tmpdir "$external_fallback"; then
      printf 'failed to prepare writable TMPDIR at %s\n' "$external_fallback" >&2
      return 1
    fi
    export TMPDIR="$external_fallback/"
    return 0
  fi

  repo_fallback="$COMMON_REPO_ROOT/target/.cargo-local/tmp/$target_segment"
  if ! mkdir -p "$repo_fallback" || ! tmpdir_is_usable "$repo_fallback"; then
    printf 'failed to prepare writable TMPDIR at %s\n' "$repo_fallback" >&2
    return 1
  fi
  export TMPDIR="$repo_fallback/"
}

cleanup_stale_leases() {
  local lease_file pid

  mkdir -p "$lease_dir"

  for lease_file in "$lease_dir"/*; do
    if [[ ! -f "$lease_file" ]]; then
      continue
    fi

    pid="$(cat "$lease_file" 2>/dev/null || true)"
    if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$lease_file"
    fi
  done
}

register_build_lease() {
  cleanup_stale_leases
  lease_path="$lease_dir/$(sanitize_segment "${session_id:-local}")-$$"
  printf '%s\n' "$$" >"$lease_path"
  cleanup_stale_leases
  active_build_count="$(find "$lease_dir" -type f | wc -l | tr -d ' ')"
  if [[ ! "$active_build_count" =~ ^[0-9]+$ ]] || (( active_build_count < 1 )); then
    active_build_count=1
  fi
}

release_build_lease() {
  if [[ -n "$lease_path" ]]; then
    rm -f "$lease_path"
  fi
}

detect_cpu_count() {
  local count=""

  if command -v getconf >/dev/null 2>&1; then
    count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  fi

  if [[ -z "$count" ]] && command -v sysctl >/dev/null 2>&1; then
    count="$(sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || true)"
  fi

  if [[ -z "$count" ]] && command -v nproc >/dev/null 2>&1; then
    count="$(nproc 2>/dev/null || true)"
  fi

  if [[ ! "$count" =~ ^[0-9]+$ ]] || (( count < 1 )); then
    count=4
  fi

  printf '%s\n' "$count"
}

default_jobs() {
  local cpu_count base_jobs
  cpu_count="$(detect_cpu_count)"

  # Agent sessions need a lower cap so parallel workers do not drown the host.
  if [[ -n "$session_id" ]]; then
    if (( cpu_count <= 4 )); then
      base_jobs=1
    elif (( cpu_count <= 8 )); then
      base_jobs=2
    elif (( cpu_count <= 12 )); then
      base_jobs=3
    else
      base_jobs=4
    fi
  else
    # Keep the machine responsive by default instead of saturating all cores.
    if (( cpu_count <= 4 )); then
      base_jobs=2
    elif (( cpu_count <= 8 )); then
      base_jobs=3
    elif (( cpu_count <= 12 )); then
      base_jobs=4
    else
      base_jobs=6
    fi
  fi

  if (( active_build_count > 1 )); then
    base_jobs=$(((base_jobs + active_build_count - 1) / active_build_count))
  fi

  if (( base_jobs < 1 )); then
    base_jobs=1
  fi

  printf '%s\n' "$base_jobs"
}

default_test_jobs() {
  local cpu_count max_jobs test_jobs
  cpu_count="$(detect_cpu_count)"

  if [[ -n "$session_id" ]]; then
    max_jobs=8
  else
    max_jobs=12
  fi
  test_jobs=$cpu_count
  if (( test_jobs > max_jobs )); then
    test_jobs=$max_jobs
  fi
  if (( active_build_count > 1 )); then
    test_jobs=$(((test_jobs + active_build_count - 1) / active_build_count))
  fi
  if (( test_jobs < 2 )); then
    test_jobs=2
  fi

  printf '%s\n' "$test_jobs"
}

session_id="$(first_nonempty_env \
  CODEX_SESSION_ID \
  CODEX_THREAD_ID \
  CLAUDE_SESSION_ID \
  CLAUDE_CODE_SESSION_ID \
  GEMINI_SESSION_ID \
  COPILOT_SESSION_ID \
  OPENCODE_SESSION_ID || true)"

if [[ "$skip_build_lease" == "1" ]]; then
  active_build_count="${HARNESS_CARGO_ACTIVE_BUILD_COUNT:-1}"
  if [[ ! "$active_build_count" =~ ^[0-9]+$ ]] || (( active_build_count < 1 )); then
    printf 'HARNESS_CARGO_ACTIVE_BUILD_COUNT must be a positive integer (got %s)\n' \
      "$active_build_count" >&2
    exit 2
  fi
else
  register_build_lease
  trap release_build_lease EXIT
fi

target_segment="local"
if [[ -n "$session_id" ]]; then
  target_segment="agent-$(sanitize_segment "$session_id")"
fi

configure_tmpdir

resolve_sccache_bin || true
if [[ -n "${SCCACHE_BIN:-}" ]]; then
  export SCCACHE_BASEDIRS="${SCCACHE_BASEDIRS:-$ROOT:$COMMON_REPO_ROOT}"
  if configure_sccache_tmpdir; then
    configure_sccache_socket || true
  else
    export SCCACHE_BIN=""
    unset SCCACHE_VERSION
  fi
fi

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-${HARNESS_CARGO_TARGET_DIR:-$COMMON_REPO_ROOT/target/dev/$target_segment}}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-${HARNESS_CARGO_JOBS:-$(default_jobs)}}"
export NEXTEST_TEST_THREADS="${NEXTEST_TEST_THREADS:-${HARNESS_NEXTEST_JOBS:-$(default_test_jobs)}}"
if [[ "$NEXTEST_TEST_THREADS" != "num-cpus" ]] \
  && [[ ! "$NEXTEST_TEST_THREADS" =~ ^([2-9]|[1-9][0-9]+)$ ]]; then
  printf 'NEXTEST_TEST_THREADS must be num-cpus or an integer greater than one (got %s)\n' \
    "$NEXTEST_TEST_THREADS" >&2
  exit 2
fi

if [[ "${1:-}" == "--print-env" ]]; then
  printf 'CARGO_TARGET_DIR=%s\n' "$CARGO_TARGET_DIR"
  printf 'CARGO_BUILD_JOBS=%s\n' "$CARGO_BUILD_JOBS"
  printf 'NEXTEST_TEST_THREADS=%s\n' "$NEXTEST_TEST_THREADS"
  printf 'CARGO_BUILD_BUILD_DIR=%s\n' "${CARGO_BUILD_BUILD_DIR:-}"
  printf 'ACTIVE_BUILD_COUNT=%s\n' "$active_build_count"
  if [[ -n "$session_id" ]]; then
    printf 'SESSION_MODE=agent\n'
  else
    printf 'SESSION_MODE=local\n'
  fi
  printf 'TMPDIR=%s\n' "${TMPDIR:-}"
  printf 'SCCACHE_SERVER_UDS=%s\n' "${SCCACHE_SERVER_UDS:-}"
  printf 'SCCACHE_IDLE_TIMEOUT=%s\n' "${SCCACHE_IDLE_TIMEOUT:-}"
  printf 'SCCACHE_CACHE_SIZE=%s\n' "${SCCACHE_CACHE_SIZE:-}"
  printf 'SCCACHE_BIN=%s\n' "${SCCACHE_BIN:-}"
  printf 'SCCACHE_VERSION=%s\n' "${SCCACHE_VERSION:-}"
  printf 'SCCACHE_BASEDIRS=%s\n' "${SCCACHE_BASEDIRS:-}"
  printf 'HARNESS_SCCACHE_TMPDIR=%s\n' "${HARNESS_SCCACHE_TMPDIR:-}"
  printf 'CARGO_INCREMENTAL=%s\n' "${CARGO_INCREMENTAL:-}"
  printf 'RUSTC_WRAPPER=%s\n' "${RUSTC_WRAPPER:-}"
  if [[ -n "${SCCACHE_BIN:-}" ]] && [[ -z "${RUSTC_WRAPPER:-}" ]]; then
    printf 'CACHE_MODE=sccache\n'
  elif [[ -n "${RUSTC_WRAPPER:-}" ]]; then
    printf 'CACHE_MODE=custom-wrapper\n'
  else
    printf 'CACHE_MODE=none\n'
  fi
  printf 'SESSION_ID=%s\n' "${session_id:-}"
  if [[ -n "${HARNESS_CARGO_LEASE_HOLD_SECONDS:-}" ]]; then
    sleep "${HARNESS_CARGO_LEASE_HOLD_SECONDS}"
  fi
  exit 0
fi

if [[ "${1:-}" == "--with-group-lease" ]]; then
  shift
  if (( $# == 0 )); then
    printf 'usage: %s --with-group-lease <command> [args...]\n' "${0##*/}" >&2
    exit 2
  fi
  export HARNESS_CARGO_SKIP_LEASE=1
  export HARNESS_CARGO_ACTIVE_BUILD_COUNT="$active_build_count"
  harness_run_step "cargo-local build group" "$@"
  exit $?
fi

if (( active_build_count > 1 )); then
  printf 'cargo-local: build contention (%d concurrent builds, using %s jobs) - if tests fail, retry after other builds finish before debugging\n' \
    "$active_build_count" "$CARGO_BUILD_JOBS" >&2
fi

cargo_bin="${HARNESS_CARGO_BIN:-cargo}"
if ! cargo_bin_usable "$cargo_bin" && [[ -x "${HOME}/.cargo/bin/cargo" ]]; then
  cargo_bin="${HOME}/.cargo/bin/cargo"
fi

if [[ "${HARNESS_CARGO_GROUP_CHILD:-0}" == "1" ]]; then
  exec "$cargo_bin" "$@"
fi

harness_run_step "cargo-local command" "$cargo_bin" "$@"
