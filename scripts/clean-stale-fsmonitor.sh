#!/usr/bin/env bash
# Identify and (optionally) kill orphan `git fsmonitor--daemon` processes.
#
# When `git worktree remove <name>` deletes a linked worktree, the daemon
# that was watching that worktree keeps running -- detached, holding inodes
# for a tree that no longer exists. With dozens of worktrees churned over
# weeks, the host accumulates dozens of these daemons, each holding kqueue
# subscriptions and worker threads.
#
# Detection: for each running `git fsmonitor--daemon` process, lsof reveals
# the `.git` or `.git/worktrees/<name>` directory it has open as a read-only
# DIR fd. That path is the daemon's gitdir; if it no longer exists on disk,
# the daemon is orphaned.
#
# Safety: dry-run by default. Pass `--apply` to kill orphans (SIGTERM). Pass
# `--orphans-only` to skip even dry-run reporting of live daemons. Live
# daemons (whose gitdir still exists) are NEVER killed by this script.
set -uo pipefail

APPLY=0
ORPHANS_ONLY=0
SIGNAL="TERM"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--apply] [--orphans-only] [--signal SIG] [-h|--help]

  --apply             Send SIGTERM to orphan daemons (default: dry-run).
  --orphans-only      Suppress lines about live daemons (only show orphans).
  --signal SIG        Signal to send (default: TERM). Try KILL only if TERM
                      is ignored.
  -h, --help          Show this help.

A daemon is "orphan" iff lsof reports its open .git[/worktrees/<name>] dir
no longer exists on disk. Live daemons (whose gitdir still exists) are
never killed even with --apply.
EOF
}

while (($#)); do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --orphans-only) ORPHANS_ONLY=1; shift ;;
    --signal) SIGNAL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# Find each running fsmonitor daemon's gitdir by inspecting its open files.
# Linked-worktree daemons open `<repo>/.git/worktrees/<name>/` as a DIR fd
# (and bind a `fsmonitor--daemon.ipc` socket relative to that dir, which
# lsof prints as just the basename). Main-repo daemons leave `.git/` un-open
# but bind the socket via the absolute path `<repo>/.git/fsmonitor--daemon.ipc`.
#
# Strategy: first scan DIR fds for `.git[/worktrees/<name>]` (catches every
# linked-worktree daemon). If nothing matches, look for an IPC socket whose
# path is absolute -- that path's dirname is the main-repo gitdir.
#
# BSD awk on macOS refuses the negated character class inside parenthesised
# alternation, so the gitdir pattern is applied with `grep -E`.
gitdir_for_pid() {
  local pid="$1"
  local lsof_output
  lsof_output="$(/usr/sbin/lsof -p "$pid" 2>/dev/null)"

  local dir_hit
  dir_hit="$(
    printf '%s\n' "$lsof_output" \
      | /usr/bin/awk '$5=="DIR" {print $9}' \
      | /usr/bin/grep -E '\.git(/worktrees/[^/]+)?$' \
      | /usr/bin/awk '{ print length($0), $0 }' \
      | /usr/bin/sort -rn \
      | /usr/bin/awk 'NR==1 { sub(/^[0-9]+ /, ""); print; exit }'
  )"
  if [[ -n "$dir_hit" ]]; then
    printf '%s\n' "$dir_hit"
    return 0
  fi

  # Absolute-path IPC socket: dirname is the gitdir. Reject the bare
  # basename `fsmonitor--daemon.ipc` (no slash) -- that means lsof reported
  # it relative to an unprintable cwd, not the absolute path we need.
  local ipc_hit
  ipc_hit="$(
    printf '%s\n' "$lsof_output" \
      | /usr/bin/awk '$NF ~ /\/fsmonitor--daemon\.ipc$/ {print $NF; exit}' \
      | /usr/bin/sed 's|/fsmonitor--daemon\.ipc$||'
  )"
  if [[ -n "$ipc_hit" ]]; then
    printf '%s\n' "$ipc_hit"
    return 0
  fi

  # Fallback for main-repo daemons where lsof shows only the basename of
  # the IPC socket: the deepest open DIR fd (ignoring system / home roots)
  # is the worktree, and `<worktree>/.git` is the gitdir.
  local deepest
  deepest="$(
    printf '%s\n' "$lsof_output" \
      | /usr/bin/awk '$5=="DIR" {print $9}' \
      | /usr/bin/grep -vE '^(/System(/.*)?$|/Users$|/$|/dev(/.*)?$|/private$)' \
      | /usr/bin/grep -v "^${HOME}\$" \
      | /usr/bin/awk '{ print length($0), $0 }' \
      | /usr/bin/sort -rn \
      | /usr/bin/awk 'NR==1 { sub(/^[0-9]+ /, ""); print; exit }'
  )"
  if [[ -n "$deepest" && -e "$deepest/.git" ]]; then
    printf '%s/.git\n' "$deepest"
  fi
}

declare -a ORPHAN_PIDS=()
declare -a ORPHAN_DESCRIPTIONS=()
live_count=0
unknown_count=0

while IFS= read -r pid; do
  [[ -n "$pid" ]] || continue
  gitdir="$(gitdir_for_pid "$pid")"
  if [[ -z "$gitdir" ]]; then
    unknown_count=$((unknown_count + 1))
    if (( ORPHANS_ONLY == 0 )); then
      printf '  · unknown   pid=%-7s gitdir=(could not determine)\n' "$pid"
    fi
    continue
  fi
  if [[ -d "$gitdir" ]]; then
    live_count=$((live_count + 1))
    if (( ORPHANS_ONLY == 0 )); then
      printf '  · live      pid=%-7s gitdir=%s\n' "$pid" "$gitdir"
    fi
    continue
  fi
  ORPHAN_PIDS+=("$pid")
  ORPHAN_DESCRIPTIONS+=("pid=$pid gitdir=$gitdir (deleted)")
  printf '  · ORPHAN    pid=%-7s gitdir=%s (deleted)\n' "$pid" "$gitdir"
done < <(/usr/bin/pgrep -f 'fsmonitor--daemon')

orphan_count=${#ORPHAN_PIDS[@]}

printf '\nlive=%d orphan=%d unknown=%d\n' "$live_count" "$orphan_count" "$unknown_count"

if (( orphan_count == 0 )); then
  printf 'No orphan fsmonitor daemons found.\n'
  exit 0
fi

if (( APPLY == 0 )); then
  printf '\nDry-run: would send SIG%s to %d orphan(s). Re-run with --apply to do it.\n' \
    "$SIGNAL" "$orphan_count"
  exit 0
fi

printf '\nSending SIG%s to %d orphan(s)...\n' "$SIGNAL" "$orphan_count"
killed=0
for i in "${!ORPHAN_PIDS[@]}"; do
  pid="${ORPHAN_PIDS[$i]}"
  desc="${ORPHAN_DESCRIPTIONS[$i]}"
  if kill -"$SIGNAL" "$pid" 2>/dev/null; then
    killed=$((killed + 1))
    printf '  killed: %s\n' "$desc"
  else
    printf '  failed: %s (process gone?)\n' "$desc"
  fi
done

printf 'killed=%d / orphans=%d\n' "$killed" "$orphan_count"
