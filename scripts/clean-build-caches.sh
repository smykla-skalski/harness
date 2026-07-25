#!/usr/bin/env bash
# Reclaim disk space from build artifacts and tool caches.
#
# Default scope (safe, no source loss, no live-app disruption):
#   - Repo Rust artifacts:   target/, crates/*/target, mcp-servers/*/target,
#                            apps/*/target, .cache/harness-monitor-xcode-daemon
#   - Repo Xcode artifacts:  xcode-derived*, xcode-derived-e2e/,
#                            xcode-derived-instruments/, tmp/
#   - Repo SwiftPM artifacts: apps/**/.build, mcp-servers/**/.build
#   - Global build caches:   ~/Library/Caches/go-build, Mozilla.sccache, Yarn,
#                            ~/.cache/tuist
#   - Tool caches:           JetBrains, Homebrew prune, swiftpm
#                            (ms-playwright is reported but NOT removed; pass --force/-f to remove it)
#
# target/ is shared across every worktree via cargo-local.sh's
# CARGO_TARGET_DIR: one target/dev/agent-<session> segment per concurrent
# agent build, or target/dev/local for a build with no session id, all
# rooted at the common repo. Segments with a live
# target/.cargo-local/leases/ entry are actively building and are kept,
# not deleted, so this script never rips a build out from under a running
# session; every other entry under target/dev/ is swept. target/.cargo-local
# itself (the lease and tmp bookkeeping cargo-local.sh depends on) is never
# touched.
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
source "$ROOT/scripts/lib/common-repo-root.sh"
COMMON_REPO_ROOT="$(resolve_common_repo_root "$ROOT")"
readonly COMMON_REPO_ROOT
SHARED_TARGET_ROOT="$COMMON_REPO_ROOT/target"
readonly SHARED_TARGET_ROOT
LEASE_DIR="$SHARED_TARGET_ROOT/.cargo-local/leases"
readonly LEASE_DIR

DRY_RUN=0
AGGRESSIVE=0
FORCE=0
TOTAL_RECLAIMED_KB=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--aggressive] [-f|--force] [-h|--help]

  --dry-run     Print targets and sizes; do not delete.
  --aggressive  Also wipe Xcode UI HarnessMonitor-* DerivedData slots.
  -f, --force   Also remove ms-playwright cache (reported-only by default).
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

# A segment (target/dev/local or target/dev/agent-<session>) is leased when
# a cargo-local.sh lease file names it with a PID that's still alive. The PID
# comes from the lease file's content (the source of truth), not parsed out
# of the filename, so session ids containing dashes or digits can't confuse
# the match.
segment_is_leased() {
  local segment="$1" key lease_file base pid
  key="$segment"
  [[ "$key" == agent-* ]] && key="${key#agent-}"
  [[ -d "$LEASE_DIR" ]] || return 1
  for lease_file in "$LEASE_DIR"/*; do
    [[ -f "$lease_file" ]] || continue
    pid="$(cat "$lease_file" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    base="$(basename "$lease_file")"
    [[ "$base" == "$key-$pid" ]] && kill -0 "$pid" 2>/dev/null && return 0
  done
  return 1
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
      seg=$(basename "$seg_dir")
      if segment_is_leased "$seg"; then
        printf '  · %-46s %8s  (active build, kept)\n' "target/dev/$seg" "$(bytes_to_human "$(path_size_kb "$seg_dir")")"
      else
        remove_path "target/dev/$seg" "$seg_dir"
      fi
    done < <(find "$SHARED_TARGET_ROOT/dev" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  fi

  while IFS= read -r -d '' entry; do
    base=$(basename "$entry")
    [[ "$base" == "dev" || "$base" == ".cargo-local" ]] && continue
    remove_path "target/$base" "$entry"
  done < <(find "$SHARED_TARGET_ROOT" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
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

section 'Global build caches'
remove_path 'go-build cache'                        "$HOME/Library/Caches/go-build"
remove_path 'Mozilla.sccache'                       "$HOME/Library/Caches/Mozilla.sccache"
remove_path 'sccache'                               "$HOME/Library/Caches/sccache"
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
    base=$(basename "$slot")
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
