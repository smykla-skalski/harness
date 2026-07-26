#!/usr/bin/env bash
set -euo pipefail
unalias -a 2>/dev/null || true

# sccache lets any client start a server when it finds none, and a starting
# server unlinks the socket path before it binds. A burst of first compilations
# therefore leaves one server reachable and every earlier one orphaned: still
# running until its idle timeout, still holding a listening socket on the same
# path, and still enforcing its own copy of SCCACHE_CACHE_SIZE over the one
# cache directory. That is an eviction fight, and it is why a 30G budget sits at
# a few gigabytes. Changing one linker flag was enough to take this host to 100
# servers at once.
#
# cargo-local.sh now starts that one server up front, so a build should no
# longer manufacture orphans. This stays for the ones already running, and for
# servers started outside that path - a plain `cargo build`, an Xcode phase.
#
# It is a task rather than part of the build path on purpose: naming the live
# server means connecting to it, which is not a price worth paying in front of
# every one of the thousands of rustc invocations a build makes.

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"

# Identifying a server needs /proc and SO_PEERCRED, so this is Linux only. The
# mise task already routes around that, but someone reading the docs and running
# the script directly deserves the same answer rather than a failure from inside
# a /proc read that does not exist.
host_os="$(uname -s)"
case "$host_os" in
  Linux) ;;
  Darwin)
    printf 'sccache: server cleanup is Linux only, skipping on macOS\n'
    exit 0
    ;;
  *)
    printf 'sccache: server cleanup is Linux only, skipping on %s\n' "$host_os"
    exit 0
    ;;
esac

# This sends signals, so an argument it does not understand is a reason to stop
# rather than something to ignore on the way to killing things.
dry_run=0
case "$#:${1:-}" in
  0:) ;;
  1:--dry-run) dry_run=1 ;;
  *)
    printf 'usage: %s [--dry-run]\n' "${0##*/}" >&2
    exit 2
    ;;
esac

socket_path="${SCCACHE_SERVER_UDS:-}"
if [[ -z "$socket_path" ]]; then
  # Guarded because set -e would otherwise abort on the assignment itself when
  # the wrapper is missing, losing the explanation below to a bare exit 127.
  socket_path="$("$ROOT/scripts/cargo-local.sh" --print-env 2>/dev/null \
    | awk -F= '/^SCCACHE_SERVER_UDS=/ {print $2; exit}' || true)"
fi

# Without the socket there is no way to tell the live server from the orphans,
# and without python3 there is no way to ask it. Carrying on either way would
# make every server look orphaned and kill the whole set, which is the opposite
# of the point.
if [[ -z "$socket_path" ]]; then
  printf 'sccache: cannot resolve SCCACHE_SERVER_UDS, refusing to guess which server is live\n' >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'sccache: python3 is required to identify the live server\n' >&2
  exit 1
fi

# Every orphan still shows as listening on this path, so "is something listening"
# cannot separate them. Connecting can: the kernel routes to whichever socket the
# path resolves to now, and SO_PEERCRED names that process.
#
# The two ways this fails are not the same and must not be treated alike. Nobody
# home - refused, or no such file - means the whole set really is orphaned and
# reaping all of it is the point. Anything else, a timeout under load most of
# all, means the answer is unknown, and killing on an unknown would take the live
# server with it. Exit 2 says the first, exit 1 says the second.
live_server_pid() {
  [[ -n "$socket_path" ]] || return 1
  python3 - "$socket_path" <<'PY' 2>/dev/null
import socket, struct, sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(2)
try:
    sock.connect(sys.argv[1])
    creds = sock.getsockopt(
        socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")
    )
except (ConnectionRefusedError, FileNotFoundError):
    sys.exit(2)
except OSError:
    sys.exit(1)
print(struct.unpack("3i", creds)[0])
PY
}

# A server's command line is the binary and nothing else. A client is
# `sccache /path/to/rustc ...`, and killing one kills a live compilation, so the
# argument count is the only safe discriminator available here.
#
# The socket is keyed per repository, so a server holding a different one belongs
# to a different checkout and its orphans are not ours to collect. Matching on
# the environment keeps this from reaching across repositories.
server_pids() {
  local pid arg_count
  for pid in $(pgrep -u "$(id -u)" -x sccache 2>/dev/null || true); do
    arg_count="$(tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null | grep -c . || true)"
    [[ "$arg_count" == "1" ]] || continue
    # -F because a socket path carries dots that would otherwise be regex, and
    # -x so the whole NUL-separated entry has to match rather than a prefix.
    grep -qzxF "SCCACHE_SERVER_UDS=$socket_path" "/proc/$pid/environ" 2>/dev/null || continue
    printf '%s\n' "$pid"
  done
}

mapfile -t servers < <(server_pids)
if ((${#servers[@]} == 0)); then
  printf 'sccache: no server processes\n'
  exit 0
fi

probe_status=0
live_pid="$(live_server_pid)" || probe_status=$?
if ((probe_status == 1)); then
  printf 'sccache: cannot tell which server owns the socket, so nothing is stopped\n' >&2
  exit 1
fi

orphans=()
for pid in "${servers[@]}"; do
  [[ "$pid" == "$live_pid" ]] && continue
  # A server that has just forked may not have bound yet, and racing it would
  # create the very orphan this is meant to remove.
  elapsed="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
  [[ "$elapsed" =~ ^[0-9]+$ ]] || continue
  ((elapsed > 60)) || continue
  orphans+=("$pid")
done

printf 'sccache: %d server(s), live=%s, %d orphaned\n' \
  "${#servers[@]}" "${live_pid:-none}" "${#orphans[@]}"
if ((${#orphans[@]} == 0)); then
  exit 0
fi

if ((dry_run)); then
  printf '  would stop: %s\n' "${orphans[*]}"
  exit 0
fi

for pid in "${orphans[@]}"; do
  kill "$pid" 2>/dev/null || true
done
printf 'sccache: stopped %d orphaned server(s)\n' "${#orphans[@]}"
