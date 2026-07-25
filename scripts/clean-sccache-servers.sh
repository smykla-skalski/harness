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
# This is a task rather than part of the build path on purpose: finding the live
# server means connecting to it, which is not a price worth paying in front of
# every one of the thousands of rustc invocations a build makes.

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"

dry_run=0
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=1
fi

socket_path="${SCCACHE_SERVER_UDS:-}"
if [[ -z "$socket_path" ]]; then
  socket_path="$("$ROOT/scripts/cargo-local.sh" --print-env 2>/dev/null \
    | awk -F= '/^SCCACHE_SERVER_UDS=/ {print $2; exit}')"
fi

# Every orphan still shows as listening on this path, so "is something listening"
# cannot separate them. Connecting can: the kernel routes to whichever socket the
# path resolves to now, and SO_PEERCRED names that process.
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
except OSError:
    sys.exit(1)
print(struct.unpack("3i", creds)[0])
PY
}

# A server's command line is the binary and nothing else. A client is
# `sccache /path/to/rustc ...`, and killing one kills a live compilation, so the
# argument count is the only safe discriminator available here.
server_pids() {
  local pid arg_count
  for pid in $(pgrep -u "$(id -u)" -x sccache 2>/dev/null || true); do
    arg_count="$(tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null | grep -c . || true)"
    [[ "$arg_count" == "1" ]] || continue
    printf '%s\n' "$pid"
  done
}

mapfile -t servers < <(server_pids)
if ((${#servers[@]} == 0)); then
  printf 'sccache: no server processes\n'
  exit 0
fi

live_pid="$(live_server_pid || true)"
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
