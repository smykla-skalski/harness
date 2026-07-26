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
# Why the pool was passed over, when it was passed over for a reason worth
# naming rather than simply being unreachable.
jobserver_skipped=""
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

# One question, answered by connecting: is a server listening on this path right
# now. The file cannot answer it - every orphaned server still holds a listening
# socket on the path it was started with, and a path left behind by a dead one
# looks identical from the filesystem.
#
# The answer is a word rather than an exit status because macOS ships a
# /usr/bin/python3 that stays a stub until the command line tools are installed
# and fails with the same status a refused connection would, and an exit code
# alone cannot separate "nothing is listening" from "could not ask".
sccache_socket_state() {
  local socket="${1:-}" verdict=""

  if [[ -n "$socket" ]] && command -v python3 >/dev/null 2>&1; then
    verdict="$(python3 - "$socket" 2>/dev/null <<'PY' || true
import errno, socket, sys

# Errors that prove nothing is serving this path: no listener, no file, or a
# file that cannot be one, since a live server's path is a socket by definition.
# Linux answers ECONNREFUSED for every non-socket, but the BSDs distinguish, and
# reading their answer as "could not ask" would leave the junk there forever.
# Anything else - a permission error, a timeout under load - stays unknown,
# because the only action taken on a definite answer is starting a second server.
NOT_SERVING = {
    errno.ECONNREFUSED,
    errno.ENOENT,
    errno.ENOTSOCK,
    errno.EISDIR,
    errno.ENOTDIR,
}

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(2)
try:
    sock.connect(sys.argv[1])
except OSError as error:
    print("absent" if error.errno in NOT_SERVING else "unknown")
else:
    print("reachable")
finally:
    sock.close()
PY
    )"
  fi

  case "$verdict" in
    reachable | absent | unknown) printf '%s\n' "$verdict" ;;
    *) printf 'unprobed\n' ;;
  esac
}

# How long a dead socket has to have been sitting there before the sweep will
# remove it. Nothing depends on the removal being prompt - a starting sccache
# server unlinks the path itself - so the only job of this number is to be longer
# than the gap between a concurrent build binding a socket and this sweep
# deciding about it.
SCCACHE_SOCKET_MIN_AGE_SECONDS=60

# GNU and BSD stat disagree on the format flag, and GNU's -f means something else
# entirely while still exiting 0, so the shape has to be validated before it is
# trusted.
socket_mtime_epoch() {
  local path="$1" mtime
  mtime="$(stat -c '%Y' "$path" 2>/dev/null || true)"
  if [[ ! "$mtime" =~ ^[0-9]+$ ]]; then
    mtime="$(stat -f '%m' "$path" 2>/dev/null || true)"
  fi
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$mtime"
}

# Unlink a socket only once a connect proves it dead and it has been there long
# enough to belong to a build that is over. Asking lsof which sockets were live
# and deleting the rest was wrong three ways: it needed lsof installed, it had to
# parse lsof's name field - whose format changed between 4.91 and 4.95, so on a
# modern lsof it unlinked the live server's socket on every run - and it judged a
# directory listing against a snapshot that could predate a socket bound while
# lsof was being asked.
#
# A connect answers about one candidate at the moment of the decision, so no
# snapshot is left to go stale, and the age check covers what remains: any socket
# a concurrent build has just bound is young, whatever this sweep decided about
# the path a moment earlier. Comparing the file instead does not work - /tmp is
# tmpfs on Linux and hands the rebound socket the inode the unlinked one had.
sweep_dead_sccache_sockets() {
  local dir="$1" sock mtime now
  [[ -d "$dir" ]] || return 0
  now="$(date +%s 2>/dev/null || true)"
  [[ "$now" =~ ^[0-9]+$ ]] || return 0

  for sock in "$dir"/*.sock; do
    [[ -e "$sock" ]] || continue
    mtime="$(socket_mtime_epoch "$sock" || true)"
    [[ "$mtime" =~ ^[0-9]+$ ]] || continue
    (( now - mtime >= SCCACHE_SOCKET_MIN_AGE_SECONDS )) || continue
    [[ "$(sccache_socket_state "$sock")" == "absent" ]] || continue
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

# An unknown - a timeout under load, a permission error - reads as reachable on
# purpose: the only action taken on "no server" is starting one, and starting a
# second server next to a live one is the failure this path exists to prevent.
#
# A probe that could not run at all falls back to the socket file, which is not
# the same as starting nothing. A path with no socket file behind it is one no
# client could reach either, so a prestart there can only help; what the fallback
# gives up is telling a live server from an orphan's leftover path.
sccache_server_reachable() {
  local socket="${SCCACHE_SERVER_UDS:-}"

  [[ -n "$socket" ]] || return 1
  case "$(sccache_socket_state "$socket")" in
    reachable | unknown) return 0 ;;
    absent) return 1 ;;
  esac

  [[ -S "$socket" ]]
}

# mkdir is the atomic primitive both platforms have; macOS ships no flock(1).
# The holder's pid goes inside so a lock left by a killed build is reclaimed
# rather than stalling every build after it.
acquire_sccache_lock() {
  local lock="$1" waited=0 owner

  while (( waited < 100 )); do
    if mkdir "$lock" 2>/dev/null; then
      # A held lock with no pid inside is one every later build reads as stale
      # and reclaims while this one still holds it, so a pid that cannot be
      # written means handing the lock straight back rather than holding one
      # that offers no serialisation.
      if ! printf '%s\n' "$$" >"$lock/pid" 2>/dev/null; then
        rm -rf "$lock" 2>/dev/null || true
        return 1
      fi
      return 0
    fi
    # Not before a second has passed: a lock taken moments ago has no pid file
    # yet, and reclaiming it would break the very serialisation it provides.
    if (( waited > 10 )); then
      owner="$(cat "$lock/pid" 2>/dev/null || true)"
      if [[ ! "$owner" =~ ^[0-9]+$ ]] || ! kill -0 "$owner" 2>/dev/null; then
        rm -rf "$lock" 2>/dev/null || true
      fi
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}

# Start the one server for this repository before cargo runs. sccache lets any
# client that finds no server start one, and a starting server unlinks the
# socket path before it binds, so a burst of first compilations leaves one
# server reachable and the rest orphaned: still running, still listening on the
# same path, and still enforcing their own copy of SCCACHE_CACHE_SIZE over the
# one cache directory. That is an eviction fight, and it is why a 30G budget
# settled at a few gigabytes. Having a server up before the first rustc leaves
# clients with nothing to start.
#
# The lock is what makes it one server rather than one per concurrent build:
# probe and start have to be a single step, or two cargo-locals starting
# together both see nothing and both start.
ensure_sccache_server() {
  local lock

  [[ -n "${SCCACHE_BIN:-}" ]] || return 0
  [[ -n "${SCCACHE_SERVER_UDS:-}" ]] || return 0
  [[ "${HARNESS_SCCACHE_PRESTART:-1}" == "1" ]] || return 0

  sccache_server_reachable && return 0

  # A lock that cannot be taken means another build is starting the server this
  # call wanted; waiting longer would buy nothing that build is not already
  # doing, so hand the work back to the clients rather than stalling here.
  lock="${SCCACHE_SERVER_UDS%.sock}.lock"
  acquire_sccache_lock "$lock" || return 0

  if ! sccache_server_reachable; then
    # TMPDIR matches what rustc-cache-wrapper.sh hands sccache, so the server's
    # scratch space does not depend on which entry point happened to start it.
    if ! TMPDIR="${HARNESS_SCCACHE_TMPDIR:-${TMPDIR:-/tmp}}/" \
      "$SCCACHE_BIN" --start-server >/dev/null 2>&1; then
      printf 'cargo-local: sccache server did not start; compilations fall back to starting their own\n' >&2
    fi
  fi

  rm -rf "$lock" 2>/dev/null || true
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

  # Set but empty means no sccache, which is how rustc-cache-wrapper.sh has
  # always read it. Reading it as "not specified" and going looking anyway turned
  # a caller's opt-out into a running server: the shell tests pass an empty value
  # for scenarios that have nothing to do with caching, and each one left a
  # server behind, bound inside a sandbox directory the suite then deleted, still
  # enforcing its own copy of the size limit over the shared cache.
  if [[ -n "${SCCACHE_BIN+set}" ]] && [[ -z "$requested" ]]; then
    export SCCACHE_BIN=""
    unset SCCACHE_VERSION
    return 1
  fi

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

# Whether a sub-make could survive being handed this pool. Cargo keeps the fifo
# endpoint out of MAKEFLAGS, but cmake-rs copies CARGO_MAKEFLAGS into MAKEFLAGS
# itself whenever the generated project is Makefile based, and make below 4.4
# does not ignore an endpoint it cannot parse - 4.3 exits 2 on one. A crate like
# aws-lc-sys would then fail the whole build, so on such a host the pool is not
# safe to attach to at all and the static reserve stands in.
make_understands_fifo_jobserver() {
  local version major minor
  command -v make >/dev/null 2>&1 || return 0
  version="$(make --version 2>/dev/null | head -1)"
  version="${version##* }"
  IFS=. read -r major minor _ <<<"$version"
  # Anything that does not answer with a version number - bmake, a wrapper - is
  # assumed unable to cope, because guessing wrong here breaks builds.
  [[ "$major" =~ ^[0-9]+$ ]] || return 1
  [[ "$minor" =~ ^[0-9]+$ ]] || minor=0
  (( major > 4 || (major == 4 && minor >= 4) ))
}

# Attach to the shared pool. Cargo speaks the jobserver protocol natively, so
# once CARGO_MAKEFLAGS points at the pool it renegotiates its own width against
# every other build for as long as it runs - which the sampled-once reserve
# cannot do. MAKEFLAGS stays empty on purpose: see the note in configure below.
configure_jobserver() {
  local line

  jobserver_mode="reserve"
  jobserver_skipped=""
  # Reserve means this script sizes the build, so an inherited jobserver must
  # not silently govern instead. A stale one - the pool this very script
  # exported before it died - pins cargo to its implicit slot while
  # CARGO_BUILD_JOBS still advertises a full share. All three go, because the
  # jobserver crate honours whichever of them it finds first.
  unset MAKEFLAGS MFLAGS CARGO_MAKEFLAGS
  if [[ "${HARNESS_JOBSERVER:-1}" == "0" ]]; then
    return 0
  fi
  command -v python3 >/dev/null 2>&1 || return 0
  [[ -f "$(jobserver_script)" ]] || return 0
  # Named so the fallback is visible. Dropping to the reserve without saying why
  # is the same silent degradation the pool exists to make impossible.
  if ! make_understands_fifo_jobserver; then
    jobserver_skipped="old-make"
    return 0
  fi

  line="$(python3 "$(jobserver_script)" ensure \
    --repo-root "$(jobserver_pool_key)" \
    --budget "$(jobserver_budget)" 2>/dev/null)" || return 0
  [[ "$line" == CARGO_MAKEFLAGS=* ]] || return 0

  # Deliberately not MAKEFLAGS. Cargo reads CARGO_MAKEFLAGS first, and make
  # never reads it at all, so a build script that shells out to make cannot
  # inherit an endpoint its make is too old to parse. GNU make 4.3 - what
  # Ubuntu 24.04 ships - exits 2 on a fifo endpoint rather than ignoring it.
  export CARGO_MAKEFLAGS="${line#CARGO_MAKEFLAGS=}"
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
target_dir="${CARGO_TARGET_DIR:-${HARNESS_CARGO_TARGET_DIR:-$COMMON_REPO_ROOT/target/dev/$target_segment}}"

# Answered before the lease is taken, because closeout reads this to find the
# lane it has to reclaim and then checks that same lane for a live lease. A
# lease registered by the query would report the lane as busy to its own caller.
if [[ "${1:-}" == "--print-target-dir" ]]; then
  printf '%s\n' "$target_dir"
  exit 0
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

export CARGO_TARGET_DIR="$target_dir"
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
  printf 'CARGO_MAKEFLAGS=%s\n' "${CARGO_MAKEFLAGS:-}"
  printf 'JOBSERVER=%s\n' "$jobserver_mode"
  printf 'JOBSERVER_SKIPPED=%s\n' "$jobserver_skipped"
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

# Below the query exits on purpose: --print-env and --print-target-dir answer a
# question about the environment, and answering one should not leave a daemon
# running behind it.
ensure_sccache_server

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
  local arg seen_nextest=0 skip_value=0
  for arg in "$@"; do
    if (( skip_value )); then
      skip_value=0
      continue
    fi
    case "$arg" in
      # Global flags whose value is a separate bare word, which would otherwise
      # read as the subcommand and make this look like something else entirely.
      # The --flag=value spelling needs no help; it already matches -*.
      --color|--config|-C|-Z) skip_value=1 ;;
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

# Place --no-run ahead of any separator. Appended at the end it would land past
# a caller's `--` and reach the test binary as one of its arguments, leaving the
# build phase to run the whole suite instead of only compiling it.
build_only_args() {
  local arg inserted=0
  build_only_argv=()
  for arg in "$@"; do
    if (( ! inserted )) && [[ "$arg" == "--" ]]; then
      build_only_argv+=(--no-run)
      inserted=1
    fi
    build_only_argv+=("$arg")
  done
  if (( ! inserted )); then
    build_only_argv+=(--no-run)
  fi
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
  build_only_args "$@"
  harness_run_step "cargo-local test build" "$cargo_bin" "${build_only_argv[@]}" || exit $?
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
