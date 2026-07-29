#!/usr/bin/env bash
# Reclaim disk space from build artifacts and tool caches.
#
# Default scope (safe, no source loss, no live-app disruption):
#   - Repo Rust artifacts:   target/, crates/*/target, mcp-servers/*/target,
#                            apps/*/target, .cache/harness-monitor-xcode-daemon
#   - Repo Xcode artifacts:  xcode-derived*, xcode-derived-e2e/,
#                            xcode-derived-instruments/, tmp/
#   - Repo SwiftPM artifacts: apps/**/.build, mcp-servers/**/.build
#   - Stale test temp dirs:  $TMPDIR/.tmpXXXXXX abandoned by killed tests
#   - Global build caches:   ~/Library/Caches/go-build, Mozilla.sccache, Yarn,
#                            ~/.cache/tuist
#   - Tool caches:           JetBrains, Homebrew prune, swiftpm
#                            (ms-playwright is reported but NOT removed; pass --force/-f to remove it)
#
# sccache is reported but NOT removed by default. A running sccache server
# pins its cache directory at startup, so deleting it out from under the server
# turns every later compile into a write error until the server restarts. The
# server is stopped at the top of the sccache step (so it never outlives its
# cache), and the cache is removed only when its total size exceeds
# SCCACHE_REMOVE_THRESHOLD_KB (100G) or --force/-f is given.
#
# target/ is shared across every worktree via cargo-local.sh's
# CARGO_TARGET_DIR: target/dev/local-v<format> for the main checkout, or
# target/dev/wt-<worktree-name>-<hash>-v<format> per linked worktree, shared by
# every session that builds in that checkout, all rooted at the common repo.
# Segments with a live target/.cargo-local/leases/ entry are actively
# building and are kept, not deleted, so this script never rips a build out
# from under a running session; every other entry under target/dev/ is
# swept. target/.cargo-local itself (the lease and tmp bookkeeping
# cargo-local.sh depends on) is never touched.
#
# --aggressive also wipes Xcode UI HarnessMonitor-* DerivedData (slow regen,
# loses SourcePackages cache - only use when truly desperate for space).
#
# --dry-run prints what would be removed plus its size, deletes nothing.
#
# A failure in any single cleanup step is reported as a warning; the script
# continues with the remaining steps so one wedged path can't strand the rest.
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
readonly ROOT
# shellcheck source=scripts/lib/common-repo-root.sh
if ! source "$ROOT/scripts/lib/common-repo-root.sh"; then
  printf 'clean-build-caches: failed to source scripts/lib/common-repo-root.sh\n' >&2
  exit 1
fi
# shellcheck source=scripts/lib/cargo-lane.sh
if ! source "$ROOT/scripts/lib/cargo-lane.sh"; then
  printf 'clean-build-caches: failed to source scripts/lib/cargo-lane.sh\n' >&2
  exit 1
fi
COMMON_REPO_ROOT="$(resolve_common_repo_root "$ROOT")"
if [[ -z "$COMMON_REPO_ROOT" ]]; then
  printf 'clean-build-caches: resolve_common_repo_root returned an empty path\n' >&2
  exit 1
fi
readonly COMMON_REPO_ROOT
SHARED_TARGET_ROOT="$COMMON_REPO_ROOT/target"
readonly SHARED_TARGET_ROOT
LEASE_DIR="$SHARED_TARGET_ROOT/.cargo-local/leases"
readonly LEASE_DIR

DRY_RUN=0
AGGRESSIVE=0
FORCE=0
TOTAL_RECLAIMED_KB=0
# sccache's cache is valuable to keep warm and expensive to rebuild, so it is
# removed only when its total footprint crosses this threshold or --force is
# given. 100 GiB is well above the 30G budget a healthy server settles at.
SCCACHE_REMOVE_THRESHOLD_KB=$((100 * 1024 * 1024))
readonly SCCACHE_REMOVE_THRESHOLD_KB
SCCACHE_AUDIT_LOG="$ROOT/.cache/diagnostics/sccache-cleanup.jsonl"
readonly SCCACHE_AUDIT_LOG
# Rust's tempfile crate names temp dirs `.tmp` plus six random characters, and
# nothing reclaims one whose owning process died mid-write. An ACP probe leak
# left 27498 of them holding 177G because no cleanup path looked at $TMPDIR.
# Three hours is far longer than any fixture legitimately outlives its test.
# Exported because the batched freshness check below runs find through sh.
STALE_TMP_MINUTES=180
export STALE_TMP_MINUTES
# Spelling the six characters as alnum classes rather than `?` is what makes the
# line-oriented set arithmetic in the sweep safe: `?` matches any byte including
# a newline, which would split one directory into two bogus lines.
STALE_TMP_GLOB='.tmp[[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]]'
readonly STALE_TMP_GLOB

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--aggressive] [-f|--force] [-h|--help]

  --dry-run     Print targets and sizes; do not delete.
  --aggressive  Also wipe Xcode UI HarnessMonitor-* DerivedData slots.
  -f, --force   Also remove sccache and ms-playwright caches (both are
                reported-only by default; sccache auto-removes over 100G).
  -h, --help    Show this help.
EOF
}

while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --aggressive) AGGRESSIVE=1 ;;
    -f|--force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

bytes_to_human() {
  local kb=$1
  if (( kb < 1024 )); then printf '%dK' "$kb"
  elif (( kb < 1024 * 1024 )); then printf '%.1fM' "$(bc -l <<<"$kb/1024")"
  elif (( kb < 1024 * 1024 * 1024 )); then printf '%.1fG' "$(bc -l <<<"$kb/1024/1024")"
  else printf '%.1fT' "$(bc -l <<<"$kb/1024/1024/1024")"
  fi
}

path_size_kb() {
  local p=$1
  [[ -e "$p" ]] || { echo 0; return; }
  du -sk "$p" 2>/dev/null | awk '{print $1}'
}

remove_path() {
  local label=$1
  local target=$2
  if [[ ! -e "$target" ]]; then
    printf '  · %-46s %8s  (absent, skip)\n' "$label" "-"
    return
  fi
  local size_kb
  size_kb=$(path_size_kb "$target")
  TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + size_kb))
  local human
  human=$(bytes_to_human "$size_kb")
  if (( DRY_RUN )); then
    printf '  · %-46s %8s  (dry-run)\n' "$label" "$human"
  else
    printf '  · %-46s %8s  removing...\n' "$label" "$human"
    if ! rm -rf -- "$target" 2>/tmp/clean-build-caches-rm.err; then
      printf '    (warning: rm failed for %s: %s)\n' "$target" "$(tr '\n' ' ' </tmp/clean-build-caches-rm.err)"
    fi
    rm -f /tmp/clean-build-caches-rm.err
  fi
}

run_cmd() {
  local label=$1
  shift
  if (( DRY_RUN )); then
    printf '  · %-46s   (dry-run) %s\n' "$label" "$*"
  else
    printf '  · %-46s   running\n' "$label"
    "$@" >/dev/null 2>&1 || printf '    (warning: %s exited non-zero)\n' "$1"
  fi
}

section() {
  printf '\n[%s]\n' "$1"
}

# sccache pins its cache directory at startup, so removing that directory while
# the server keeps running turns every later compile into a write error until
# the server restarts. Stopping it first lets the next build start a fresh
# server against the recreated directory. The repo's server is resolved the
# same way clean-sccache-servers.sh does: from cargo-local.sh's authoritative
# --print-env. `--stop-server` works on both platforms, unlike the /proc-based
# orphan reaper, because the target is the one server owning this checkout's
# socket, not one orphan among many.
stop_repo_sccache_server() {
  local env uds bin
  env="$("$ROOT/scripts/cargo-local.sh" --print-env 2>/dev/null || true)"
  uds="$(awk -F= '/^SCCACHE_SERVER_UDS=/ {print $2; exit}' <<<"$env")"
  bin="$(awk -F= '/^SCCACHE_BIN=/ {print $2; exit}' <<<"$env")"
  SCCACHE_SELECTED_SOCKET="$uds"
  SCCACHE_SELECTED_PIDS=""
  if [[ -n "$uds" ]]; then
    while IFS= read -r pid; do
      if [[ "$pid" =~ ^[0-9]+$ ]]; then
        SCCACHE_SELECTED_PIDS="${SCCACHE_SELECTED_PIDS}${pid}"$'\n'
      fi
    done < <(python3 "$ROOT/scripts/lib/sccache_processes.py" --socket "$uds" 2>/dev/null || true)
  fi
  [[ -n "$uds" ]] || {
    SCCACHE_STOP_OUTCOME="server-unidentified"
    return 0
  }
  if [[ ! -S "$uds" && -z "$SCCACHE_SELECTED_PIDS" ]]; then
    SCCACHE_STOP_OUTCOME="server-absent"
    return 0
  fi
  if [[ -z "$bin" || ! -x "$bin" || ! -S "$uds" ]]; then
    printf '    (warning: configured sccache server is present but cannot be stopped; cache kept)\n'
    SCCACHE_STOP_OUTCOME="server-unidentified"
    return 1
  fi

  if (( DRY_RUN )); then
    printf '  · %-46s   (dry-run) %s\n' 'stop sccache server' "--stop-server"
    SCCACHE_STOP_OUTCOME="dry-run-would-stop"
    return 0
  fi
  printf '  · %-46s   stopping\n' 'stop sccache server'
  # A failed stop leaves a server that may still hold the cache directory, so
  # return non-zero and let the caller keep the cache rather than risk deleting
  # it under a live server - the exact failure this script exists to prevent.
  SCCACHE_SERVER_UDS="$uds" "$bin" --stop-server >/dev/null 2>&1 || {
    printf '    (warning: sccache --stop-server failed; cache kept to avoid deleting under a live server)\n'
    SCCACHE_STOP_OUTCOME="failed"
    return 1
  }
  SCCACHE_STOP_OUTCOME="stopped"
}

write_sccache_cleanup_audit() {
  local preview="$1" mode reason total_kb
  shift
  mode="normal"
  (( AGGRESSIVE )) && mode="aggressive"
  (( FORCE )) && mode="$mode+force"
  reason="$1"
  total_kb="$2"
  shift 2
  local -a command=(
    python3 "$ROOT/scripts/sccache-cleanup-audit.py"
    --log "$SCCACHE_AUDIT_LOG"
    --mode "$mode"
    --size-kb "$total_kb"
    "--reason=$reason"
    --threshold-kb "$SCCACHE_REMOVE_THRESHOLD_KB"
    --server-socket "$SCCACHE_SELECTED_SOCKET"
    --stop-outcome "$SCCACHE_STOP_OUTCOME"
  )
  local path pid
  for path in "$@"; do command+=(--cache-path "$path"); done
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] && command+=(--server-pid "$pid")
  done <<<"$SCCACHE_SELECTED_PIDS"
  (( preview )) && command+=(--preview)
  "${command[@]}"
}

# sccache is reported but kept by default: its cache is valuable to keep warm
# and expensive to rebuild, and rebuilding it recompiles every dependency. It is
# removed only when the total across its cache dirs exceeds the threshold, or
# --force is given. Either way the server is stopped first so a running server
# never outlives its cache directory. Mozilla.sccache and Library/Caches/sccache
# are the macOS defaults; ~/.cache/sccache is the Linux one (and sccache's
# documented default there), which the previous version never listed.
clean_sccache_caches() {
  local -a dirs=()
  local dir total_kb=0 size_kb over_threshold remove='' reason audit_reason

  for dir in \
    "$HOME/Library/Caches/Mozilla.sccache" \
    "$HOME/Library/Caches/sccache" \
    "$HOME/.cache/sccache"; do
    [[ -e "$dir" ]] || continue
    # Resolve to the physical path before deduping. The macOS pair can alias the
    # same directory through a symlinked Caches, and a literal-string compare
    # would count that directory twice and double its weight against the threshold.
    local resolved
    resolved="$(CDPATH='' cd -P -- "$dir" 2>/dev/null && pwd -P)" || resolved="$dir"
    local existing
    for existing in "${dirs[@]:-}"; do
      [[ "$existing" == "$resolved" ]] && continue 2
    done
    dirs+=("$resolved")
    # Size the resolved physical path, not $dir: du -sk on a symlink to a
    # directory reports 0, so sizing the unresolved path would undercount a
    # cache reached through a symlinked ~/Library/Caches and could keep an
    # oversized cache below the threshold.
    size_kb="$(path_size_kb "$resolved")"
    total_kb=$((total_kb + size_kb))
  done

  if ((${#dirs[@]} == 0)); then
    printf '  · %-46s %8s  (absent, skip)\n' 'sccache cache' '-'
    return
  fi

  over_threshold=0
  (( total_kb > SCCACHE_REMOVE_THRESHOLD_KB )) && over_threshold=1
  if (( FORCE )); then
    remove=1
    reason='--force'
  elif (( over_threshold )); then
    # Multiple servers enforce independent 30G limits while writing the same
    # directory, so leaked servers can collectively outrun one server's budget.
    # The 100G host guard remains the final disk-safety boundary.
    remove=1
    reason="over $(bytes_to_human "$SCCACHE_REMOVE_THRESHOLD_KB") threshold"
  else
    remove=0
    reason="kept: under $(bytes_to_human "$SCCACHE_REMOVE_THRESHOLD_KB"); pass -f/--force to remove"
  fi

  SCCACHE_SELECTED_SOCKET=""
  SCCACHE_SELECTED_PIDS=""
  SCCACHE_STOP_OUTCOME="not-needed"
  if (( remove )); then
    audit_reason="$reason"
    if ! stop_repo_sccache_server; then
      remove=0
      reason='kept: sccache server did not stop; retry clean:caches or stop it manually'
    fi
    if (( DRY_RUN )); then
      printf '    audit preview: '
      write_sccache_cleanup_audit 1 "$audit_reason" "$total_kb" "${dirs[@]}"
    elif ! write_sccache_cleanup_audit 0 "$audit_reason" "$total_kb" "${dirs[@]}" >/dev/null; then
      printf '    (warning: sccache cleanup audit failed; cache kept)\n'
      remove=0
      reason='kept: destructive cleanup could not be audited'
    fi
  fi

  printf '  · %-46s %8s  total\n' 'sccache cache' "$(bytes_to_human "$total_kb")"
  for dir in "${dirs[@]}"; do
    size_kb="$(path_size_kb "$dir")"
    local rel=${dir#"$HOME/"}
    if (( DRY_RUN )); then
      if (( remove )); then
        printf '  · %-46s %8s  (dry-run, would remove: %s)\n' "$rel" "$(bytes_to_human "$size_kb")" "$reason"
      else
        printf '  · %-46s %8s  (dry-run, %s)\n' "$rel" "$(bytes_to_human "$size_kb")" "$reason"
      fi
    elif (( remove )); then
      remove_path "$rel" "$dir"
    else
      printf '  · %-46s %8s  (%s)\n' "$rel" "$(bytes_to_human "$size_kb")" "$reason"
    fi
  done
}

# A versioned segment under target/dev is leased
# when a cargo-local.sh lease file names it with a PID that's still alive.
segment_is_leased() {
  cargo_lane_segment_is_leased "$LEASE_DIR" "$1"
}

# Sweeps the shared target/ tree at the common repo root: each entry
# directly under target/dev/ (segment directory, or a stray file/symlink)
# with a live lease is kept and not counted as reclaimed; everything else
# under target/dev/ and any other top-level entry under target/ is removed.
clean_shared_target() {
  if [[ ! -d "$SHARED_TARGET_ROOT" ]]; then
    printf '  · %-46s %8s  (absent, skip)\n' 'repo target/' '-'
    return
  fi

  local seg_dir seg entry base
  if [[ -d "$SHARED_TARGET_ROOT/dev" ]]; then
    while IFS= read -r -d '' seg_dir; do
      seg=$(basename -- "$seg_dir")
      if segment_is_leased "$seg"; then
        printf '  · %-46s %8s  (active build, kept)\n' "target/dev/$seg" "$(bytes_to_human "$(path_size_kb "$seg_dir")")"
      else
        remove_path "target/dev/$seg" "$seg_dir"
      fi
    done < <(find "$SHARED_TARGET_ROOT/dev" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  fi

  while IFS= read -r -d '' entry; do
    base=$(basename -- "$entry")
    [[ "$base" == "dev" || "$base" == ".cargo-local" ]] && continue
    remove_path "target/$base" "$entry"
  done < <(find "$SHARED_TARGET_ROOT" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

# Sweeps abandoned tempfile-crate directories out of $TMPDIR. A directory
# survives when anything inside it changed within the window, not just when its
# own mtime is recent: a long suite writes deep in its fixture without touching
# the top level, so trusting the directory mtime alone would delete a live
# fixture out from under it. Reports counts rather than one line per directory
# because a neglected $TMPDIR holds tens of thousands of these, and sizing each
# one separately would take minutes.
clean_stale_test_temp_dirs() {
  local tmp_root="${TMPDIR:-/tmp}"
  tmp_root="${tmp_root%/}"
  if [[ ! -d "$tmp_root" ]]; then
    printf '  · %-46s %8s  (absent, skip)\n' 'stale .tmp dirs' '-'
    return
  fi

  # Returning quietly here would leave the report claiming a sweep that never
  # ran, which is the same failure the sweep exists to stop hiding.
  local work
  if ! work="$(mktemp -d "${TMPDIR:-/tmp}/clean-build-caches-sweep.XXXXXX" 2>/dev/null)"; then
    printf '  · %-46s %8s  (no scratch dir, skipped)\n' 'stale .tmp dirs' '-'
    return
  fi

  # STALE_TMP_GLOB admits only alphanumerics, so a candidate path cannot contain
  # a newline and the line-oriented set arithmetic below is safe.
  find "$tmp_root" -maxdepth 1 -mindepth 1 -type d -name "$STALE_TMP_GLOB" \
    -mmin "+$STALE_TMP_MINUTES" -print 2>/dev/null | sort > "$work/candidates"
  local recent_count
  recent_count=$(find "$tmp_root" -maxdepth 1 -mindepth 1 -type d -name "$STALE_TMP_GLOB" \
    ! -mmin "+$STALE_TMP_MINUTES" -print 2>/dev/null | wc -l | tr -d ' ')

  # One batched find across every candidate spots the trees with live writes.
  # A find per directory instead takes minutes once $TMPDIR holds tens of
  # thousands of these, which is exactly when the sweep matters most. It goes
  # through sh because xargs appends its arguments, and find needs its search
  # roots before the expression, not after it.
  : > "$work/stale"
  if [[ -s "$work/candidates" ]]; then
    # shellcheck disable=SC2016  # $STALE_TMP_MINUTES is exported, so the inner
    # sh expands it itself; expanding it here would bake the value into the
    # script text instead of leaving it to the child.
    tr '\n' '\0' < "$work/candidates" \
      | xargs -0 -n 200 sh -c 'find "$@" -mmin "-$STALE_TMP_MINUTES" -print 2>/dev/null' sweep \
      | awk -v prefix="$tmp_root/" '
          index($0, prefix) == 1 {
            rest = substr($0, length(prefix) + 1)
            split(rest, parts, "/")
            if (parts[1] != "") print prefix parts[1]
          }' \
      | sort -u > "$work/live"
    grep -Fxv -f "$work/live" "$work/candidates" > "$work/stale" 2>/dev/null || true
  fi

  local stale_count kept_count size_kb=0
  stale_count=$(wc -l < "$work/stale" | tr -d ' ')
  kept_count=$(( recent_count + $(wc -l < "$work/candidates" | tr -d ' ') - stale_count ))

  if (( stale_count > 0 )); then
    size_kb=$(tr '\n' '\0' < "$work/stale" \
      | xargs -0 -n 50 du -sk 2>/dev/null \
      | awk '{total += $1} END {print total + 0}')
    TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + size_kb))
  fi

  local human
  human=$(bytes_to_human "$size_kb")
  if (( DRY_RUN )); then
    printf '  · %-46s %8s  (dry-run)\n' "stale .tmp dirs ($stale_count)" "$human"
  else
    printf '  · %-46s %8s  removing...\n' "stale .tmp dirs ($stale_count)" "$human"
    if (( stale_count > 0 )); then
      # A silent failure here would report reclaimed bytes that are still on
      # disk, so surface it the way remove_path does.
      if ! tr '\n' '\0' < "$work/stale" | xargs -0 -n 50 rm -rf 2>"$work/rm.err"; then
        printf '    (warning: some stale temp dirs survived: %s)\n' \
          "$(tr '\n' ' ' < "$work/rm.err")"
      fi
    fi
  fi
  printf '  · %-46s %8s\n' "recent .tmp dirs kept ($kept_count)" '-'
  rm -rf "$work"
}

disk_free_g() {
  df -k / | awk 'NR==2 {printf "%.1fG free of %.1fG (%s used)", $4/1024/1024, $2/1024/1024, $5}'
}

printf '== clean-build-caches =='
(( DRY_RUN )) && printf ' (dry-run)'
(( AGGRESSIVE )) && printf ' (aggressive)'
printf '\nbefore: %s\n' "$(disk_free_g)"

section 'Rust artifacts'
clean_shared_target
remove_path 'daemon cargo target'                   "$ROOT/.cache/harness-monitor-xcode-daemon"
while IFS= read -r -d '' tdir; do
  rel=${tdir#"$ROOT/"}
  remove_path "$rel"                                "$tdir"
done < <(find "$ROOT/apps" "$ROOT/crates" "$ROOT/mcp-servers" -mindepth 2 -type d -name target -prune -print0 2>/dev/null)

section 'Xcode artifacts (project-local)'
remove_path 'xcode-derived/'                        "$ROOT/xcode-derived"
remove_path 'xcode-derived-e2e/'                    "$ROOT/xcode-derived-e2e"
remove_path 'xcode-derived-lanes/'                  "$ROOT/xcode-derived-lanes"
remove_path 'xcode-derived-instruments/'            "$ROOT/xcode-derived-instruments"

section 'SwiftPM artifacts (project-local)'
while IFS= read -r -d '' tdir; do
  rel=${tdir#"$ROOT/"}
  remove_path "$rel"                                "$tdir"
done < <(find "$ROOT/apps" "$ROOT/mcp-servers" -mindepth 2 -type d -name '.build' -prune -print0 2>/dev/null)

section 'Repo tmp + scratch'
remove_path 'tmp/'                                  "$ROOT/tmp"

section 'Stale test temp dirs'
clean_stale_test_temp_dirs

section 'Global build caches'
remove_path 'go-build cache'                        "$HOME/Library/Caches/go-build"
clean_sccache_caches
remove_path 'Yarn cache'                            "$HOME/Library/Caches/Yarn"
remove_path 'swiftpm cache'                         "$HOME/Library/Caches/org.swift.swiftpm"
remove_path 'gopls cache'                           "$HOME/Library/Caches/gopls"
remove_path 'goimports cache'                       "$HOME/Library/Caches/goimports"
remove_path 'golangci-lint cache'                   "$HOME/Library/Caches/golangci-lint"
remove_path 'tuist cache'                           "$HOME/.cache/tuist"

section 'Tool caches'
remove_path 'JetBrains caches'                      "$HOME/Library/Caches/JetBrains"
if (( FORCE )); then
  remove_path 'ms-playwright cache'                 "$HOME/Library/Caches/ms-playwright"
fi
# Keep Copilot warm state intact; clean:caches is meant to reclaim disposable build/test caches.
if command -v brew >/dev/null 2>&1; then
  run_cmd 'brew cleanup --prune=all'                brew cleanup -s --prune=all
fi
if command -v go >/dev/null 2>&1; then
  run_cmd 'go clean -cache -modcache -fuzzcache'    go clean -cache -modcache -fuzzcache
fi
if command -v mise >/dev/null 2>&1; then
  run_cmd 'mise prune (unused tool versions)'       mise prune --yes
fi

if (( AGGRESSIVE )); then
  section 'Xcode UI DerivedData (aggressive)'
  while IFS= read -r -d '' slot; do
    base=$(basename -- "$slot")
    remove_path "$base"                             "$slot"
  done < <(find "$HOME/Library/Developer/Xcode/DerivedData" -mindepth 1 -maxdepth 1 \
            \( -name 'HarnessMonitor-*' -o -name 'HarnessMonitorRegistry-*' -o -name 'HarnessMonitorUIPreviews-*' \) -print0 2>/dev/null)
  remove_path 'CompilationCache.noindex'            "$HOME/Library/Developer/Xcode/DerivedData/CompilationCache.noindex"
  remove_path 'ModuleCache.noindex'                 "$HOME/Library/Developer/Xcode/DerivedData/ModuleCache.noindex"
fi

printf '\n== summary ==\n'
printf 'reclaimed (target sizes summed): %s\n' "$(bytes_to_human "$TOTAL_RECLAIMED_KB")"
printf 'after:  %s\n' "$(disk_free_g)"
(( DRY_RUN )) && printf '(dry-run; no files were deleted)\n'
if ! (( FORCE )); then
  _pw_kb=$(path_size_kb "$HOME/Library/Caches/ms-playwright")
  if [[ -e "$HOME/Library/Caches/ms-playwright" ]]; then
    printf 'ms-playwright cache: %s (pass -f/--force to remove)\n' "$(bytes_to_human "$_pw_kb")"
  fi
fi
exit 0
