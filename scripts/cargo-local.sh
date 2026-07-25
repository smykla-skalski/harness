#!/usr/bin/env bash
set -euo pipefail
unalias -a 2>/dev/null || true

# Physical path: COMMON_REPO_ROOT comes from git and is already resolved, and
# the two are compared below to tell a linked worktree from the main checkout.
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
# shellcheck source=scripts/lib/run-step.sh
source "$ROOT/scripts/lib/run-step.sh"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$ROOT/scripts/lib/common-repo-root.sh"
COMMON_REPO_ROOT="$(resolve_common_repo_root "$ROOT")"
lease_dir="$COMMON_REPO_ROOT/target/.cargo-local/leases"
lease_path=""
active_build_count=1
# How many concurrent agent builds a single agent assumes it must leave room
# for when the lease count cannot tell it yet.
AGENT_BUILD_SHARE=4
# "pool" once attached to the shared jobserver, "reserve" on the static fallback.
jobserver_mode="reserve"
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

  safe_user="$(sanitize_segment "${USER:-user}")"
  socket_root="${sccache_socket_root:-${TMPDIR:-/tmp}}"
  socket_root="${socket_root%/}/harness-sccache"
  # Straight under world-writable /tmp the name has to carry the user, the way
  # the long-path fallback always has. The socket name is a deterministic hash
  # of a guessable path, so a shared root lets another local user bind it first.
  if [[ "$socket_root" == "/tmp/harness-sccache" ]] || (( ${#socket_root} > 70 )); then
    socket_root="/tmp/harness-sccache-$safe_user"
  fi

  # Ownership and mode matter here for the same reason: a plain mkdir -p adopts
  # a pre-existing directory whatever its owner.
  if ! prepare_private_tmpdir "$socket_root"; then
    return 1
  fi

  sweep_dead_sccache_sockets "$socket_root"
  if [[ "$socket_root" != "/tmp/harness-sccache-$safe_user" ]]; then
    sweep_dead_sccache_sockets "/tmp/harness-sccache-$safe_user"
  fi

  # Every server enforces its own size limit over the same on-disk cache, so
  # keying the socket per checkout put several of them in an eviction fight.
  # One server per repository keeps a single owner of that cache.
  socket_id="$(short_hash "$COMMON_REPO_ROOT")"
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

  # Scratch files stay per session even though the build cache is per checkout,
  # so concurrent sessions in one worktree cannot collide over a shared TMPDIR.
  tmpdir_id="$(short_hash "${UID:-${USER:-user}}:$COMMON_REPO_ROOT:$ROOT:${session_id:-local}")"
  external_fallback="/tmp/harness-cargo-$tmpdir_id"
  if tmpdir_is_usable "/tmp"; then
    if ! prepare_private_tmpdir "$external_fallback"; then
      printf 'failed to prepare writable TMPDIR at %s\n' "$external_fallback" >&2
      return 1
    fi
    export TMPDIR="$external_fallback/"
    return 0
  fi

  # Same ownership and symlink guarantees the /tmp fallback gets. A plain
  # mkdir -p would adopt a pre-existing directory, or follow a symlink out of
  # the repository, and the per-session isolation above would mean nothing.
  # The base has to be checked too, not just the session directory inside it.
  # A symlinked or foreign-owned base is accepted by mkdir -p, and the session
  # directory created underneath it would look perfectly private while sitting
  # somewhere another user controls.
  repo_fallback="$COMMON_REPO_ROOT/target/.cargo-local/tmp"
  if ! mkdir -p "${repo_fallback%/*}" || ! prepare_private_tmpdir "$repo_fallback"; then
    printf 'failed to prepare private TMPDIR base at %s\n' "$repo_fallback" >&2
    return 1
  fi
  if ! prepare_private_tmpdir "$repo_fallback/$tmpdir_id"; then
    printf 'failed to prepare writable TMPDIR at %s\n' "$repo_fallback/$tmpdir_id" >&2
    return 1
  fi
  export TMPDIR="$repo_fallback/$tmpdir_id/"
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
  lease_path="$lease_dir/$target_segment-$$"
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

# One concurrency model for everything this script sizes. The lease count is
# sampled once, before the process starts working, and agents arrive
# independently with no way to renegotiate afterwards, so an agent assumes a
# full field of agents until the observed count is larger. Widening the divisor
# is what reserves that room - dividing a second time would starve every late
# arrival instead.
concurrency_share() {
  local budget="$1" divisor share

  divisor=$active_build_count
  if [[ -n "$session_id" ]] && (( divisor < AGENT_BUILD_SHARE )); then
    divisor=$AGENT_BUILD_SHARE
  fi
  if (( divisor < 1 )); then
    divisor=1
  fi

  share=$(((budget + divisor - 1) / divisor))
  if (( share < 1 )); then
    share=1
  fi

  printf '%s\n' "$share"
}

jobserver_script() {
  printf '%s\n' "$ROOT/scripts/harness-jobserver.py"
}

jobserver_pool_key() {
  printf '%s\n' "${HARNESS_JOBSERVER_POOL_KEY:-$COMMON_REPO_ROOT}"
}

# One token short of the CPU count: every cargo may run a single unit of work
# without holding a token, so the pool plus that implicit slot lands on the
# machine's real width rather than one above it.
jobserver_budget() {
  local budget=$(($(detect_cpu_count) - 1))
  if (( budget < 1 )); then
    budget=1
  fi
  printf '%s\n' "$budget"
}

# Attach to the shared pool. Cargo speaks the jobserver protocol natively, so
# once MAKEFLAGS points at the pool it renegotiates its own width against every
# other build for as long as it runs - which the sampled-once reserve cannot do.
configure_jobserver() {
  local line

  jobserver_mode="reserve"
  if [[ "${HARNESS_JOBSERVER:-1}" == "0" ]]; then
    return 0
  fi
  command -v python3 >/dev/null 2>&1 || return 0
  [[ -f "$(jobserver_script)" ]] || return 0

  line="$(python3 "$(jobserver_script)" ensure \
    --repo-root "$(jobserver_pool_key)" \
    --budget "$(jobserver_budget)" 2>/dev/null)" || return 0
  [[ "$line" == MAKEFLAGS=* ]] || return 0

  export MAKEFLAGS="${line#MAKEFLAGS=}"
  jobserver_mode="pool"
}

default_jobs() {
  # Under the pool the cap belongs to the token count, not to this process. A
  # reserve applied on top would throttle a build twice and strand tokens.
  if [[ "$jobserver_mode" == "pool" ]]; then
    detect_cpu_count
    return 0
  fi
  concurrency_share "$(detect_cpu_count)"
}

default_test_jobs() {
  local test_jobs
  test_jobs="$(concurrency_share "$(detect_cpu_count)")"

  # Test processes hold the same share as build jobs: a group runs one phase or
  # the other, never both, so sizing them alike keeps the reserve honest. Two is
  # the floor because the override validation below rejects a single thread.
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

# Key the build cache by checkout, not by session. Session keying handed every
# new agent a cold rebuild of the whole workspace, and Cargo's incremental
# output is opaque to sccache, so no shared cache could absorb that cost.
# register_build_lease below keys the lease file the same way, so
# clean-build-caches.sh can match a target/dev/<segment> directory straight
# against a lease file instead of reverse-engineering it from a session id.
target_segment="local"
if [[ "$ROOT" != "$COMMON_REPO_ROOT" ]]; then
  target_segment="wt-$(sanitize_segment "$(basename -- "$ROOT")")-$(short_hash "$ROOT")"
fi

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

# Capture the socket root before configure_tmpdir can install a session-scoped
# TMPDIR. Letting the socket follow that TMPDIR would hand every session its own
# server again, however repo-scoped the socket id is.
if tmpdir_is_usable "${TMPDIR:-}"; then
  sccache_socket_root="${TMPDIR%/}"
else
  sccache_socket_root="/tmp"
fi

configure_tmpdir

resolve_sccache_bin || true
if [[ -n "${SCCACHE_BIN:-}" ]]; then
  # sccache reads these only in the process that starts the server, so a
  # per-worktree value would make path normalization depend on whichever
  # checkout happened to start it. Keep it repo-wide and predictable.
  export SCCACHE_BASEDIRS="${SCCACHE_BASEDIRS:-$COMMON_REPO_ROOT}"
  # Swallowing a socket failure would leave sccache enabled on whatever default
  # endpoint it picks, which can be a localhost TCP port any local user can
  # reach. Losing the cache is the safer trade.
  if ! configure_sccache_tmpdir || ! configure_sccache_socket; then
    export SCCACHE_BIN=""
    unset SCCACHE_VERSION
  fi
fi

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-${HARNESS_CARGO_TARGET_DIR:-$COMMON_REPO_ROOT/target/dev/$target_segment}}"
# An explicit thread count is the caller's decision, so record that before the
# default lands on top of it - the pool must not renegotiate a chosen width.
nextest_threads_explicit=0
if [[ -n "${NEXTEST_TEST_THREADS:-}" ]] || [[ -n "${HARNESS_NEXTEST_JOBS:-}" ]]; then
  nextest_threads_explicit=1
fi

configure_jobserver
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
  printf 'MAKEFLAGS=%s\n' "${MAKEFLAGS:-}"
  printf 'JOBSERVER=%s\n' "$jobserver_mode"
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

# True only for `nextest run`. `nextest list` builds but runs no tests, so it
# wants the pool for its build and no test block at all.
command_is_nextest_run() {
  local arg seen_nextest=0
  for arg in "$@"; do
    case "$arg" in
      # A toolchain selector precedes the subcommand and is not a flag.
      +*) ;;
      -*) ;;
      nextest)
        if (( seen_nextest )); then
          return 1
        fi
        seen_nextest=1
        ;;
      run) (( seen_nextest )) && return 0; return 1 ;;
      *) return 1 ;;
    esac
  done
  return 1
}

already_no_run() {
  local arg
  for arg in "$@"; do
    [[ "$arg" == "--no-run" ]] && return 0
  done
  return 1
}

# nextest does not speak the jobserver protocol and has said it will not, so its
# test width cannot renegotiate mid-run and has to be fixed up front. Its two
# halves want opposite things, though: the build wants the pool, and holding a
# block across it would starve the compile that produces the very binaries the
# block is for. So build first against the full pool, then take the block and
# run - by then cargo has nothing left to compile.
if [[ "$jobserver_mode" == "pool" ]] \
  && (( nextest_threads_explicit == 0 )) \
  && command_is_nextest_run "$@" \
  && ! already_no_run "$@"; then
  harness_run_step "cargo-local test build" "$cargo_bin" "$@" --no-run || exit $?
  harness_run_step "cargo-local command" \
    python3 "$(jobserver_script)" run \
    --repo-root "$(jobserver_pool_key)" \
    --max "$(jobserver_budget)" \
    --env NEXTEST_TEST_THREADS \
    --floor 2 \
    -- "$cargo_bin" "$@"
  exit $?
fi

harness_run_step "cargo-local command" "$cargo_bin" "$@"
