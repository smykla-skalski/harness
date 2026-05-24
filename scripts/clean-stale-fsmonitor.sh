#!/usr/bin/env bash
# Identify and (optionally) kill orphan and redundant `git fsmonitor--daemon`
# processes.
#
# When `git worktree remove <name>` deletes a linked worktree, the daemon
# that was watching that worktree keeps running -- detached, holding inodes
# for a tree that no longer exists. With dozens of worktrees churned over
# weeks, the host accumulates dozens of these daemons, each holding kqueue
# subscriptions and worker threads.
#
# Additionally, git can spawn multiple daemons for the same gitdir under
# concurrent first-`git status` races: each process loses the bind() race
# but lives on with an unbound socket. Observed today: merbridge/merbridge
# had four daemons for one gitdir, several other repos had two each. Only
# the newest daemon owns the active IPC socket; the others are wasted state.
#
# Detection: for each running `git fsmonitor--daemon` process, lsof reveals
# the `.git` or `.git/worktrees/<name>` directory it has open as a read-only
# DIR fd. That path is the daemon's gitdir.
#   - "orphan"    iff the gitdir no longer exists on disk.
#   - "redundant" iff another daemon is already watching the same gitdir;
#                 the oldest daemons are redundant, the newest is kept.
#   - "live"      otherwise.
#
# Safety: dry-run by default. Pass `--apply` to kill orphans AND redundants
# (SIGTERM). Pass `--orphans-only` to skip dry-run reporting of live daemons.
# A live (non-redundant) daemon is NEVER killed by this script.
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

# pid_etimes_seconds returns how many seconds PID has been running. Used to
# pick the newest daemon when multiple daemons watch the same gitdir.
pid_etimes_seconds() {
  local pid="$1"
  /bin/ps -o etimes= -p "$pid" 2>/dev/null | /usr/bin/tr -d ' \t\n'
}

# Pass 1: collect (pid, classification, gitdir) tuples and a per-gitdir
# count. We can't declare a daemon "live" until we've seen every other
# daemon: if two daemons share a gitdir, only the newest is genuinely live;
# the rest are redundant. Print order matches pgrep's pid order so the
# operator can correlate this output with concurrent `ps` output.
declare -a ENTRY_PIDS=()
declare -a ENTRY_GITDIRS=()
declare -a ENTRY_CLASSES=()  # one of: unknown, orphan, live (later: redundant)
declare -A GITDIR_FIRST_INDEX=()
declare -A GITDIR_BEST_PID=()
declare -A GITDIR_BEST_ETIMES=()
declare -A GITDIR_DUP_COUNT=()

while IFS= read -r pid; do
  [[ -n "$pid" ]] || continue
  gitdir="$(gitdir_for_pid "$pid")"
  if [[ -z "$gitdir" ]]; then
    ENTRY_PIDS+=("$pid")
    ENTRY_GITDIRS+=("")
    ENTRY_CLASSES+=("unknown")
    continue
  fi
  if [[ ! -d "$gitdir" ]]; then
    ENTRY_PIDS+=("$pid")
    ENTRY_GITDIRS+=("$gitdir")
    ENTRY_CLASSES+=("orphan")
    continue
  fi
  ENTRY_PIDS+=("$pid")
  ENTRY_GITDIRS+=("$gitdir")
  ENTRY_CLASSES+=("live")
  GITDIR_DUP_COUNT["$gitdir"]=$(( ${GITDIR_DUP_COUNT["$gitdir"]:-0} + 1 ))
  if [[ -z "${GITDIR_FIRST_INDEX["$gitdir"]:-}" ]]; then
    GITDIR_FIRST_INDEX["$gitdir"]=$((${#ENTRY_PIDS[@]} - 1))
  fi
  local_etimes="$(pid_etimes_seconds "$pid")"
  [[ "$local_etimes" =~ ^[0-9]+$ ]] || local_etimes=999999999
  if [[ -z "${GITDIR_BEST_PID["$gitdir"]:-}" ]] \
      || (( local_etimes < ${GITDIR_BEST_ETIMES["$gitdir"]:-999999999} )); then
    GITDIR_BEST_PID["$gitdir"]="$pid"
    GITDIR_BEST_ETIMES["$gitdir"]="$local_etimes"
  fi
done < <(/usr/bin/pgrep -f 'fsmonitor--daemon')

# Pass 2: flip stale duplicates from "live" to "redundant". The newest
# daemon (lowest etimes) keeps its "live" classification; everyone else
# sharing that gitdir becomes "redundant" and is eligible for kill.
declare -a ORPHAN_PIDS=()
declare -a ORPHAN_DESCRIPTIONS=()
declare -a REDUNDANT_PIDS=()
declare -a REDUNDANT_DESCRIPTIONS=()
live_count=0
unknown_count=0

for i in "${!ENTRY_PIDS[@]}"; do
  pid="${ENTRY_PIDS[$i]}"
  gitdir="${ENTRY_GITDIRS[$i]}"
  class="${ENTRY_CLASSES[$i]}"
  case "$class" in
    unknown)
      unknown_count=$((unknown_count + 1))
      if (( ORPHANS_ONLY == 0 )); then
        printf '  · unknown   pid=%-7s gitdir=(could not determine)\n' "$pid"
      fi
      ;;
    orphan)
      ORPHAN_PIDS+=("$pid")
      ORPHAN_DESCRIPTIONS+=("pid=$pid gitdir=$gitdir (deleted)")
      printf '  · ORPHAN    pid=%-7s gitdir=%s (deleted)\n' "$pid" "$gitdir"
      ;;
    live)
      if (( ${GITDIR_DUP_COUNT["$gitdir"]:-1} > 1 )) \
          && [[ "${GITDIR_BEST_PID["$gitdir"]}" != "$pid" ]]; then
        REDUNDANT_PIDS+=("$pid")
        REDUNDANT_DESCRIPTIONS+=("pid=$pid gitdir=$gitdir (duplicate; kept pid=${GITDIR_BEST_PID["$gitdir"]})")
        printf '  · REDUNDANT pid=%-7s gitdir=%s (duplicate; keeping newer pid=%s)\n' \
          "$pid" "$gitdir" "${GITDIR_BEST_PID["$gitdir"]}"
      else
        live_count=$((live_count + 1))
        if (( ORPHANS_ONLY == 0 )); then
          printf '  · live      pid=%-7s gitdir=%s\n' "$pid" "$gitdir"
        fi
      fi
      ;;
  esac
done

orphan_count=${#ORPHAN_PIDS[@]}
redundant_count=${#REDUNDANT_PIDS[@]}
kill_count=$((orphan_count + redundant_count))

printf '\nlive=%d orphan=%d redundant=%d unknown=%d\n' \
  "$live_count" "$orphan_count" "$redundant_count" "$unknown_count"

if (( kill_count == 0 )); then
  printf 'No orphan or redundant fsmonitor daemons found.\n'
  exit 0
fi

if (( APPLY == 0 )); then
  printf '\nDry-run: would send SIG%s to %d orphan(s) and %d redundant duplicate(s). Re-run with --apply to do it.\n' \
    "$SIGNAL" "$orphan_count" "$redundant_count"
  exit 0
fi

printf '\nSending SIG%s to %d orphan(s) and %d redundant duplicate(s)...\n' \
  "$SIGNAL" "$orphan_count" "$redundant_count"
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
for i in "${!REDUNDANT_PIDS[@]}"; do
  pid="${REDUNDANT_PIDS[$i]}"
  desc="${REDUNDANT_DESCRIPTIONS[$i]}"
  if kill -"$SIGNAL" "$pid" 2>/dev/null; then
    killed=$((killed + 1))
    printf '  killed: %s\n' "$desc"
  else
    printf '  failed: %s (process gone?)\n' "$desc"
  fi
done

printf 'killed=%d / targets=%d (orphans=%d redundant=%d)\n' \
  "$killed" "$kill_count" "$orphan_count" "$redundant_count"
