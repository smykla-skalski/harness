#!/usr/bin/env bash
# Reclaim disk by dropping stale shared Harness Monitor build lanes and stale
# linked worktrees. A build lane counts as active when either Swift/Xcode
# compile artifacts or its per-lane daemon cargo target were touched within the
# lane staleness window. A linked worktree counts as active when any non-cache
# file inside it was touched within the worktree staleness window.
#
# Always preserved:
#   - xcode-derived/ (the default shared lane for local main/Xcode use)
#   - the main worktree
#   - the current checkout running the task
#   - any lane name passed via --keep
#
# Use this instead of `clean:caches` when parallel agents are mid-flight and
# blowing away every lane/worktree would force a wave of cold rebuilds.
set -uo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
readonly SCRIPT_DIR
CHECKOUT_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
readonly CHECKOUT_ROOT
# shellcheck source=scripts/lib/common-repo-root.sh
source "$CHECKOUT_ROOT/scripts/lib/common-repo-root.sh"

COMMON_ROOT="${_HARNESS_INTERNAL_TEST_ONLY_CLEAN_LANES_COMMON_ROOT:-$(resolve_common_repo_root "$CHECKOUT_ROOT")}"
readonly COMMON_ROOT
CURRENT_WORKTREE_ROOT="$(git -C "${PWD:-$CHECKOUT_ROOT}" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$CHECKOUT_ROOT")"
readonly CURRENT_WORKTREE_ROOT
MAIN_WORKTREE_ROOT="$(git -C "$COMMON_ROOT" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$COMMON_ROOT")"
readonly MAIN_WORKTREE_ROOT
LANE_ROOT="$COMMON_ROOT/xcode-derived-lanes"
SPECIAL_LANE_NAMES=("e2e" "instruments")
SPECIAL_LANE_PATHS=("$COMMON_ROOT/xcode-derived-e2e" "$COMMON_ROOT/xcode-derived-instruments")
STALENESS_HOURS=3
WORKTREE_STALENESS_HOURS=12
DRY_RUN=0
declare -a KEEP_LANES=()

total_kept=0
total_dropped=0
total_dropped_kb=0
lane_drops=0
worktree_drops=0
lane_keeps=0
worktree_keeps=0
lanes_touched=0
worktrees_touched=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--keep LANE]... [--hours N] [--worktree-hours N] [-h|--help]

  --dry-run           Print stale lanes/worktrees and sizes; do not delete.
  --keep LANE         Preserve LANE even when stale (repeatable).
  --hours N           Lane activity window in hours (default 3).
  --worktree-hours N  Worktree activity window in hours (default 12).
  -h, --help          Show this help.
EOF
}

while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --keep)
      [[ $# -ge 2 ]] || { echo "missing value for --keep" >&2; usage >&2; exit 2; }
      KEEP_LANES+=("$2")
      shift 2
      ;;
    --hours|--lane-hours)
      [[ $# -ge 2 ]] || { echo "missing value for --hours" >&2; usage >&2; exit 2; }
      STALENESS_HOURS=$2
      shift 2
      ;;
    --worktree-hours)
      [[ $# -ge 2 ]] || { echo "missing value for --worktree-hours" >&2; usage >&2; exit 2; }
      WORKTREE_STALENESS_HOURS=$2
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! [[ "$STALENESS_HOURS" =~ ^[0-9]+$ ]]; then
  printf 'clean-stale-lanes: --hours must be an integer, got %s\n' "$STALENESS_HOURS" >&2
  exit 2
fi
if ! [[ "$WORKTREE_STALENESS_HOURS" =~ ^[0-9]+$ ]]; then
  printf 'clean-stale-lanes: --worktree-hours must be an integer, got %s\n' "$WORKTREE_STALENESS_HOURS" >&2
  exit 2
fi

is_kept_lane() {
  local lane="$1" kept
  for kept in "${KEEP_LANES[@]:-}"; do
    [[ "$kept" == "$lane" ]] && return 0
  done
  return 1
}

window_minutes() {
  local hours="$1"
  printf '%s\n' "$((hours * 60))"
}

path_size_kb() {
  local path="$1"
  [[ -e "$path" ]] || { echo 0; return; }
  du -sk "$path" 2>/dev/null | awk '{print $1}'
}

bytes_to_human() {
  local kb="$1"
  if (( kb < 1024 )); then
    printf '%dK' "$kb"
  elif (( kb < 1024 * 1024 )); then
    awk -v value="$kb" 'BEGIN { printf "%.1fM", value / 1024 }'
  else
    awk -v value="$kb" 'BEGIN { printf "%.1fG", value / 1024 / 1024 }'
  fi
}

human_size() {
  bytes_to_human "$(path_size_kb "$1")"
}

recent_path_hit() {
  local root="$1"
  shift
  local hit=""
  hit=$(find "$root" "$@" -print -quit 2>/dev/null)
  [[ -n "$hit" ]]
}

lane_is_active() {
  local dir="$1"
  local window_min
  window_min="$(window_minutes "$STALENESS_HOURS")"
  recent_path_hit "$dir" \
    -type f \
    \( -name "*.swiftmodule" -o -name "*.o" -o -name "*.dia" -o -path "*/cargo-target/*" \) \
    -mmin "-$window_min"
}

worktree_is_active() {
  local path="$1"
  local window_min
  window_min="$(window_minutes "$WORKTREE_STALENESS_HOURS")"
  recent_path_hit "$path" \
    \( -path "$path/.git" -o -path "$path/.git/*" \
      -o -path "$path/target" -o -path "$path/target/*" \
      -o -path "$path/tmp" -o -path "$path/tmp/*" \
      -o -path "$path/.build" -o -path "$path/.build/*" \
      -o -path "$path/xcode-derived" -o -path "$path/xcode-derived/*" \
      -o -path "$path/xcode-derived-lanes" -o -path "$path/xcode-derived-lanes/*" \
      -o -path "$path/xcode-derived-e2e" -o -path "$path/xcode-derived-e2e/*" \
      -o -path "$path/xcode-derived-instruments" -o -path "$path/xcode-derived-instruments/*" \) \
    -prune -o \
    -type f -mmin "-$window_min"
}

record_keep() {
  local kind="$1"
  local reason="$2"
  local name="$3"
  local path="$4"
  printf '  · keep (%-7s) %-32s %8s\n' "$reason" "$name" "$(human_size "$path")"
  total_kept=$((total_kept + 1))
  if [[ "$kind" == "lane" ]]; then
    lane_keeps=$((lane_keeps + 1))
  else
    worktree_keeps=$((worktree_keeps + 1))
  fi
}

record_drop() {
  local kind="$1"
  local name="$2"
  local path="$3"
  local size_kb="$4"
  total_dropped=$((total_dropped + 1))
  total_dropped_kb=$((total_dropped_kb + size_kb))
  if [[ "$kind" == "lane" ]]; then
    lane_drops=$((lane_drops + 1))
  else
    worktree_drops=$((worktree_drops + 1))
  fi
  if (( DRY_RUN )); then
    printf '  · drop (dry-run) %-32s %8s\n' "$name" "$(bytes_to_human "$size_kb")"
  else
    printf '  · dropped        %-32s %8s\n' "$name" "$(bytes_to_human "$size_kb")"
  fi
}

drop_lane() {
  local lane="$1"
  local path="$2"
  local size_kb
  size_kb="$(path_size_kb "$path")"
  if (( ! DRY_RUN )); then
    rm -rf -- "$path"
  fi
  record_drop "lane" "$lane" "$path" "$size_kb"
}

drop_worktree() {
  local label="$1"
  local path="$2"
  local size_kb
  size_kb="$(path_size_kb "$path")"
  if (( ! DRY_RUN )) && [[ -e "$path" ]]; then
    git -C "$COMMON_ROOT" worktree remove --force -- "$path" >/dev/null 2>&1 || {
      printf '  · warn           %-32s %8s  remove failed; kept\n' "$label" "$(bytes_to_human "$size_kb")" >&2
      return 1
    }
  fi
  record_drop "worktree" "$label" "$path" "$size_kb"
}

process_lane() {
  local lane="$1"
  local path="$2"
  [[ -d "$path" ]] || return 0
  lanes_touched=$((lanes_touched + 1))
  if is_kept_lane "$lane"; then
    record_keep "lane" "forced" "$lane" "$path"
    return 0
  fi
  if lane_is_active "$path"; then
    record_keep "lane" "active" "$lane" "$path"
    return 0
  fi
  drop_lane "$lane" "$path"
}

process_worktree() {
  local path="$1"
  local branch="$2"
  local label
  worktrees_touched=$((worktrees_touched + 1))
  label="$branch"
  if [[ "$path" == "$MAIN_WORKTREE_ROOT" ]]; then
    record_keep "worktree" "main" "$label" "$path"
    return 0
  fi
  if [[ "$path" == "$CURRENT_WORKTREE_ROOT" ]]; then
    record_keep "worktree" "current" "$label" "$path"
    return 0
  fi
  if [[ ! -e "$path" ]]; then
    drop_worktree "$label" "$path" || return 1
    return 0
  fi
  if worktree_is_active "$path"; then
    record_keep "worktree" "active" "$label" "$path"
    return 0
  fi
  drop_worktree "$label" "$path"
}

purge_launch_services() {
  local purge_ls="$COMMON_ROOT/scripts/clean-stale-launch-services.sh"
  [[ -x "$purge_ls" ]] || return 0
  if (( DRY_RUN )); then
    "$purge_ls" --dry-run || true
  else
    "$purge_ls" || true
  fi
}

printf '== clean-stale-lanes =='
(( DRY_RUN )) && printf ' (dry-run)'
printf '\ncommon-root: %s\n' "$COMMON_ROOT"
printf 'current-worktree: %s\n' "$CURRENT_WORKTREE_ROOT"
printf 'lane-window: %sh | worktree-window: %sh\n' "$STALENESS_HOURS" "$WORKTREE_STALENESS_HOURS"

printf '\n[lanes]\n'
if [[ -d "$LANE_ROOT" ]]; then
  while IFS= read -r -d '' lane_dir; do
    process_lane "$(basename "$lane_dir")" "$lane_dir"
  done < <(find "$LANE_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi

lane_index=0
for special_path in "${SPECIAL_LANE_PATHS[@]}"; do
  process_lane "${SPECIAL_LANE_NAMES[$lane_index]}" "$special_path"
  lane_index=$((lane_index + 1))
done

printf '\n[worktrees]\n'
while IFS=$'\t' read -r path branch; do
  [[ -n "$path" ]] || continue
  process_worktree "$path" "$branch"
done < <(
  git -C "$COMMON_ROOT" worktree list --porcelain 2>/dev/null \
    | awk '
        /^worktree / { path = substr($0, 10) }
        /^branch / { branch = substr($0, 8); sub("refs/heads/", "", branch); print path "\t" branch }
        /^detached$/ { print path "\t(detached)" }
      '
)

if (( ! DRY_RUN )); then
  git -C "$COMMON_ROOT" worktree prune >/dev/null 2>&1 || true
fi

printf '\n== summary ==\n'
if (( DRY_RUN )); then
  printf 'Would drop %d lane(s) and %d worktree(s), %s total. Kept %d lane(s) and %d worktree(s).\n' \
    "$lane_drops" "$worktree_drops" "$(bytes_to_human "$total_dropped_kb")" "$lane_keeps" "$worktree_keeps"
else
  printf 'Dropped %d lane(s) and %d worktree(s), %s reclaimed. Kept %d lane(s) and %d worktree(s).\n' \
    "$lane_drops" "$worktree_drops" "$(bytes_to_human "$total_dropped_kb")" "$lane_keeps" "$worktree_keeps"
fi
printf 'Scanned %d lane(s) and %d worktree(s).\n' "$lanes_touched" "$worktrees_touched"

# Dropped lanes take their built app bundles with them, leaving dead Launch
# Services registrations behind. Purge them so the io.harnessmonitor.app
# bundle-id namespace stays unambiguous for the managed daemon's BTM container
# lookup; only gone-from-disk entries are touched.
purge_launch_services
