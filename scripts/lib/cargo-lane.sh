#!/usr/bin/env bash
# Shared bookkeeping for cargo-local.sh build lanes: which directory a checkout
# builds into, and whether a build still owns it. Every cleanup path that can
# delete a lane has to agree on both, or one of them rips a build out from under
# a running session, or misses a lane nothing else will ever reclaim.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'error: cargo-lane.sh must be sourced, not executed directly\n' >&2
  exit 1
fi

# Mirrors cargo-local.sh's target_segment for a linked worktree. The caller owns
# the main-checkout case, which cargo-local.sh names "local". Both fall back the
# same way, because a host without shasum still has to name the same directory
# the build wrote to. A test pins this against `cargo-local.sh
# --print-target-dir`, since a derivation that drifts stops matching live lanes
# and starts reclaiming them out from under their worktree.
cargo_lane_segment_for_path() {
  local path="$1" name digest
  name="$(printf '%s' "$(basename -- "$path")" | tr -cs '[:alnum:]._-' '-')"
  if command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s' "$path" | shasum -a 256)"
    digest="${digest%% *}"
  elif command -v cksum >/dev/null 2>&1; then
    digest="$(printf '%s' "$path" | cksum)"
    digest="${digest//[^[:alnum:]]/}"
  else
    digest="$(printf '%s' "$path" | tr -cs '[:alnum:]._-' '-')"
  fi
  printf 'wt-%s-%s\n' "$name" "${digest:0:16}"
}

# kill -0 fails both when a PID is gone and when it belongs to another user we
# can't signal, so it alone can't tell "dead" from "alive but foreign". ps -p
# reports existence without needing signal permission, so a PID that fails
# kill -0 but shows up in ps is still treated as alive.
cargo_lane_pid_is_alive() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null && return 0
  ps -p "$pid" >/dev/null 2>&1
}

# cargo-local.sh names the lease file after the same target_segment it uses for
# the directory, so the match is a direct string compare, not a reconstruction.
# The PID comes from the file's content rather than the filename, so a segment
# name carrying dashes and digits - every wt-* segment does - can't confuse it.
cargo_lane_segment_is_leased() {
  local lease_dir="$1" segment="$2" lease_file base pid
  [[ -d "$lease_dir" ]] || return 1
  for lease_file in "$lease_dir"/*; do
    [[ -f "$lease_file" ]] || continue
    pid="$(cat "$lease_file" 2>/dev/null || true)"
    # Rejecting 0 matters: kill -0 0 signals the caller's own process group and
    # succeeds, so a truncated lease would read as a live build and pin its
    # segment forever. cargo-local.sh only ever writes $$, so anything that is
    # not a plain positive integer is a corrupt lease and protects nothing.
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
    base="$(basename -- "$lease_file")"
    [[ "$base" == "$segment-$pid" ]] && cargo_lane_pid_is_alive "$pid" && return 0
  done
  return 1
}
