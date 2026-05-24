#!/usr/bin/env bash
# Reclaim disk by dropping xcode-derived-lanes/ entries with no recent build
# activity. A lane counts as active when a *.swiftmodule, *.o, or *.dia file
# was modified within the last STALENESS_HOURS (default 2). Everything else
# under xcode-derived-lanes/ is removed.
#
# Always preserved:
#   - xcode-derived/ (the default unnamed lane; not under xcode-derived-lanes/)
#   - any lane name passed via --keep
#
# Use this instead of `clean:caches` when parallel agents are mid-flight and
# blowing away every lane would force a wave of cold rebuilds.
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
readonly ROOT
LANE_ROOT="$ROOT/xcode-derived-lanes"
STALENESS_HOURS=2
DRY_RUN=0
declare -a KEEP_LANES=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--keep LANE]... [--hours N] [-h|--help]

  --dry-run    Print stale lanes and sizes; do not delete.
  --keep LANE  Preserve LANE even when stale (repeatable).
  --hours N    Activity window in hours (default 2).
  -h, --help   Show this help.
EOF
}

while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --keep) KEEP_LANES+=("$2"); shift 2 ;;
    --hours) STALENESS_HOURS=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ ! -d "$LANE_ROOT" ]; then
  printf 'clean-stale-lanes: %s does not exist; nothing to do.\n' "$LANE_ROOT"
  exit 0
fi

is_kept() {
  local lane="$1" kept
  for kept in "${KEEP_LANES[@]:-}"; do
    [ "$kept" = "$lane" ] && return 0
  done
  return 1
}

lane_is_active() {
  local dir="$1"
  local window_min=$((STALENESS_HOURS * 60))
  # Look for any compile artifact modified within the window. -mmin avoids
  # piping into stat -- on macOS, `xargs stat -f '%m'` with empty input
  # prints filesystem info (containing the literal "Inodes:") which then
  # poisons any downstream arithmetic that reads the result.
  local hit
  hit=$(find "$dir" -type f \
      \( -name "*.swiftmodule" -o -name "*.o" -o -name "*.dia" \) \
      -mmin "-$window_min" 2>/dev/null \
    | head -1)
  [ -n "$hit" ]
}

human_size() {
  du -sh "$1" 2>/dev/null | awk '{print $1}'
}

total_kept=0
total_dropped=0
total_dropped_kb=0

for d in "$LANE_ROOT"/*/; do
  [ -d "$d" ] || continue
  lane=$(basename "$d")
  if is_kept "$lane"; then
    printf '  · keep (forced)  %-40s %8s\n' "$lane" "$(human_size "$d")"
    total_kept=$((total_kept + 1))
    continue
  fi
  if lane_is_active "$d"; then
    printf '  · keep (active)  %-40s %8s\n' "$lane" "$(human_size "$d")"
    total_kept=$((total_kept + 1))
    continue
  fi
  size_kb=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
  total_dropped_kb=$((total_dropped_kb + size_kb))
  total_dropped=$((total_dropped + 1))
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  · drop (dry-run) %-40s %8s\n' "$lane" "$(human_size "$d")"
  else
    rm -rf "$d"
    printf '  · dropped        %-40s %8s\n' "$lane" "$(awk -v kb="$size_kb" 'BEGIN{printf "%dM", kb/1024}')"
  fi
done

echo ""
human_total=$(( total_dropped_kb / 1024 / 1024 ))
if [ "$DRY_RUN" -eq 1 ]; then
  printf 'Would drop %d lane(s), %d GB. Kept %d.\n' "$total_dropped" "$human_total" "$total_kept"
else
  printf 'Dropped %d lane(s), %d GB reclaimed. Kept %d.\n' "$total_dropped" "$human_total" "$total_kept"
fi
