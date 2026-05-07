#!/usr/bin/env bash
# T1 deeper system cleanup beyond clean:caches.
#
# Targets system state that auto-regenerates on demand:
#   - Old Nix generations + nix-collect-garbage.
#   - Stale Simulator runtimes: iOS 17.x, watchOS 10.x, and any duplicate
#     iOS major where one build is unused.
#   - Xcode testmanagerd Daemon Containers (XCResultBundle scratch).
#   - Xcode CompilationCache.noindex (Apple regenerates).
#
# Skips the active Xcode UI HarnessMonitor-* DerivedData slots; use
# scripts/clean-build-caches.sh --aggressive to wipe those.
set -euo pipefail

DRY_RUN=0
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) echo "Usage: $(basename "$0") [--dry-run]"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

bytes_to_human() {
  local b=${1:-0}
  if (( b < 1024 )); then printf '%dB' "$b"
  elif (( b < 1024**2 )); then printf '%.1fK' "$(bc -l <<<"$b/1024")"
  elif (( b < 1024**3 )); then printf '%.1fM' "$(bc -l <<<"$b/1024/1024")"
  else printf '%.1fG' "$(bc -l <<<"$b/1024/1024/1024")"
  fi
}

path_size_bytes() {
  [[ -e "$1" ]] || { echo 0; return; }
  du -sk "$1" 2>/dev/null | awk '{print $1*1024}'
}

remove_path() {
  local label=$1 target=$2
  if [[ ! -e "$target" ]]; then
    printf '  · %-50s %8s  (absent)\n' "$label" "-"
    return
  fi
  local size
  size=$(path_size_bytes "$target")
  printf '  · %-50s %8s' "$label" "$(bytes_to_human "$size")"
  if (( DRY_RUN )); then
    printf '  (dry-run)\n'
  else
    printf '  removing...\n'
    rm -rf -- "$target"
  fi
}

run_cmd() {
  local label=$1; shift
  if (( DRY_RUN )); then
    printf '  · %-50s   (dry-run) %s\n' "$label" "$*"
  else
    printf '  · %-50s   running\n' "$label"
    "$@" 2>&1 | sed 's/^/      /' || true
  fi
}

disk_free_g() {
  df -k / | awk 'NR==2 {printf "%.1fG free of %.1fG (%s used)", $4/1024/1024, $2/1024/1024, $5}'
}

printf '== clean-system-state =='
(( DRY_RUN )) && printf ' (dry-run)'
printf '\nbefore: %s\n' "$(disk_free_g)"

printf '\n[Nix garbage collection]\n'
if command -v nix-collect-garbage >/dev/null 2>&1; then
  run_cmd 'nix-collect-garbage --delete-old' nix-collect-garbage --delete-old
elif command -v nix-store >/dev/null 2>&1; then
  run_cmd 'nix-store --gc'                   nix-store --gc
else
  printf '  · nix not on PATH, skipping\n'
fi

printf '\n[Stale Simulator runtimes]\n'
if command -v xcrun >/dev/null 2>&1; then
  runtime_json=$(xcrun simctl runtime list -j 2>/dev/null || echo '{}')
  helper="$(dirname "$0")/lib/list-stale-sim-runtimes.py"
  candidate_ids=$(printf '%s' "$runtime_json" | python3 "$helper" 2>/dev/null)
  if [[ -z "$candidate_ids" ]]; then
    printf '  · no stale runtimes detected\n'
  else
    while IFS=$'\t' read -r rid plat ver build size last; do
      [[ -n "$rid" ]] || continue
      label="$plat $ver ($build) lastUsed=$last"
      printf '  · %-50s %8s' "$label" "$(bytes_to_human "$size")"
      if (( DRY_RUN )); then
        printf '  (dry-run)\n'
      else
        printf '  deleting...\n'
        xcrun simctl runtime delete "$rid" 2>&1 | sed 's/^/      /' || true
      fi
    done <<<"$candidate_ids"
  fi
else
  printf '  · xcrun not on PATH, skipping\n'
fi

printf '\n[Xcode Daemon Containers]\n'
DCROOT="$HOME/Library/Daemon Containers"
if [[ -d "$DCROOT" ]]; then
  while IFS= read -r -d '' meta; do
    dir=$(dirname "$meta")
    creator=$(plutil -extract MCMMetadataCreator raw "$meta" 2>/dev/null || echo "")
    [[ "$creator" == "com.apple.testmanagerd" ]] || continue
    base=$(basename "$dir")
    remove_path "testmanagerd container $base" "$dir"
  done < <(find "$DCROOT" -mindepth 2 -maxdepth 2 -name '.com.apple.containermanagerd.metadata.plist' -print0 2>/dev/null)
else
  printf '  · no Daemon Containers dir\n'
fi

printf '\n[Xcode CompilationCache]\n'
remove_path 'DerivedData CompilationCache.noindex'   "$HOME/Library/Developer/Xcode/DerivedData/CompilationCache.noindex"
remove_path 'DerivedData ModuleCache.noindex'        "$HOME/Library/Developer/Xcode/DerivedData/ModuleCache.noindex"
remove_path 'DerivedData SymbolCache.noindex'        "$HOME/Library/Developer/Xcode/DerivedData/SymbolCache.noindex"
remove_path 'DerivedData SDKStatCaches.noindex'      "$HOME/Library/Developer/Xcode/DerivedData/SDKStatCaches.noindex"

printf '\n== summary ==\nafter:  %s\n' "$(disk_free_g)"
(( DRY_RUN )) && printf '(dry-run; nothing was deleted)\n'
exit 0
