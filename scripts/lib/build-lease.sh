#!/usr/bin/env bash
# Shared reader for cargo-local.sh build leases. While a build owns a target
# segment, cargo-local.sh holds <lease-dir>/<segment>-<pid>. Every cleanup path
# that can delete a segment has to agree on when that lease is real, or one of
# them rips a build out from under a running session.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'error: build-lease.sh must be sourced, not executed directly\n' >&2
  exit 1
fi

# kill -0 fails both when a PID is gone and when it belongs to another user we
# can't signal, so it alone can't tell "dead" from "alive but foreign". ps -p
# reports existence without needing signal permission, so a PID that fails
# kill -0 but shows up in ps is still treated as alive.
build_lease_pid_is_alive() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null && return 0
  ps -p "$pid" >/dev/null 2>&1
}

# cargo-local.sh names the lease file after the same target_segment it uses for
# the directory, so the match is a direct string compare, not a reconstruction.
# The PID comes from the file's content rather than the filename, so a segment
# name carrying dashes and digits - every wt-* segment does - can't confuse it.
build_lease_segment_is_leased() {
  local lease_dir="$1" segment="$2" lease_file base pid
  [[ -d "$lease_dir" ]] || return 1
  for lease_file in "$lease_dir"/*; do
    [[ -f "$lease_file" ]] || continue
    pid="$(cat "$lease_file" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    base="$(basename -- "$lease_file")"
    [[ "$base" == "$segment-$pid" ]] && build_lease_pid_is_alive "$pid" && return 0
  done
  return 1
}
