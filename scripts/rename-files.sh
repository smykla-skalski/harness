#!/usr/bin/env bash
# Filename rename helper for the Dependencies → Reviews rename.
#
# Usage: rename-files.sh <path-or-file> [more-paths...]
#
# Walks each given path, applies the same substring rename rules as
# rename-dependencies-to-reviews.sh to each filename and directory name,
# and renames via `git mv` (if the path is git-tracked) or plain `mv`
# (otherwise — e.g. memory files under ~/.claude/).
#
# Renames bottom-up so child renames happen before parent directories
# move out from under them.
#
# Files explicitly NOT renamed (must keep historical names for migration):
#   - HarnessMonitorSchemaV21.swift
#   - HarnessMonitorMigrationV*.swift
#   - the rename scripts themselves

set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage: $0 <path-or-file> [more-paths...]

Renames files and directories matching Dependencies-feature names to
Reviews-feature names. Operates bottom-up. Uses git mv when possible.
EOF
  exit 64
}

[[ $# -ge 1 ]] || usage

# Apply the filename-level substring transform.
new_name() {
  local name="$1"
  name="${name//HarnessMonitorDependencies/HarnessMonitorReviews}"
  name="${name//HarnessMonitorDependency/HarnessMonitorReview}"
  name="${name//DashboardDependencies/DashboardReviews}"
  name="${name//DashboardDependency/DashboardReview}"
  name="${name//SettingsDependencies/SettingsReviews}"
  name="${name//SettingsDependency/SettingsReview}"
  name="${name//DependenciesPreferences/ReviewsPreferences}"
  name="${name//DependencyCommands/ReviewCommands}"
  name="${name//OpenAnythingDashboardDependencyRegistry/OpenAnythingDashboardReviewRegistry}"
  name="${name//CachedDependencyUpdatesSnapshot/CachedReviewsSnapshot}"
  name="${name//CachedDependencyUpdatesRepoSyncState/CachedReviewsRepoSyncState}"
  name="${name//CachedDependencyUpdateFilesSummary/CachedReviewFilesSummary}"
  name="${name//CachedDependencyUpdateFileViewedState/CachedReviewFileViewedState}"
  name="${name//CachedDependencyUpdateFile/CachedReviewFile}"
  name="${name//CachedDependencyRepositoryLabels/CachedReviewRepositoryLabels}"
  name="${name//CachedDependencyLabelUsage/CachedReviewLabelUsage}"
  name="${name//CachedDependencyUpdates/CachedReviews}"
  name="${name//CachedDependencyUpdate/CachedReview}"
  name="${name//CachedDependency/CachedReview}"
  name="${name//DependencyUpdatesGitHubClient/ReviewsGitHubClient}"
  name="${name//DependencyUpdatesRepoSyncStateCache/ReviewsRepoSyncStateCache}"
  name="${name//DependencyUpdateFilesViewModel/ReviewFilesViewModel}"
  name="${name//DependencyUpdateTimelineViewModel/ReviewTimelineViewModel}"
  name="${name//DependencyUpdateLocalCloneProgress/ReviewLocalCloneProgress}"
  name="${name//DependencyUpdateFilePatchStore/ReviewFilePatchStore}"
  name="${name//DependencyUpdateImageDecoder/ReviewImageDecoder}"
  name="${name//DependencyUpdateBodyStore/ReviewBodyStore}"
  name="${name//DependencyUpdateAvatarCache/ReviewAvatarCache}"
  name="${name//DependencyUpdateFilesCache/ReviewFilesCache}"
  name="${name//DependencyUpdateBot/ReviewBot}"
  name="${name//DependencyUpdateFile/ReviewFile}"
  name="${name//DependencyPullRequestTimelineNodeBuilder/ReviewPullRequestTimelineNodeBuilder}"
  name="${name//DependencyFilesPerf/ReviewFilesPerf}"
  name="${name//DependencyTimelinePerf/ReviewTimelinePerf}"
  name="${name//DependencyUpdatesCache/ReviewsCache}"
  name="${name//DependencyUpdates/Reviews}"
  name="${name//DependencyUpdate/Review}"
  name="${name//dependency_updates_files_/reviews_files_}"
  name="${name//dependency_updates_/reviews_}"
  name="${name//dependency_update_/review_}"
  name="${name//dependency_updates/reviews}"
  name="${name//dependency-updates/reviews}"
  name="${name//project_dependencies_/project_reviews_}"
  name="${name//project_dependency_/project_review_}"
  name="${name//project_deps_/project_reviews_}"
  name="${name//project_dep_/project_review_}"
  name="${name//project_per_repo_dep_/project_per_repo_review_}"
  echo "$name"
}

skip_basename() {
  case "$1" in
    HarnessMonitorSchemaV21.swift) return 0 ;;
    HarnessMonitorMigrationV*.swift) return 0 ;;
    rename-dependencies-to-reviews.sh) return 0 ;;
    rename-files.sh) return 0 ;;
    validate-reviews-rename.sh) return 0 ;;
    .rename-allow.txt) return 0 ;;
  esac
  return 1
}

is_git_tracked() {
  local path="$1"
  ( cd "$(dirname "$path")" && git ls-files --error-unmatch -- "$(basename "$path")" ) >/dev/null 2>&1
}

rename_one() {
  local old="$1"
  local base new_base new_path
  base="$(basename "$old")"
  if skip_basename "$base"; then
    return
  fi
  new_base="$(new_name "$base")"
  if [[ "$new_base" == "$base" ]]; then
    return
  fi
  new_path="$(dirname "$old")/$new_base"
  if is_git_tracked "$old"; then
    ( cd "$(dirname "$old")" && git mv -- "$base" "$new_base" )
  else
    mv -- "$old" "$new_path"
  fi
  echo "  renamed $old -> $new_path"
}

walk_path() {
  local path="$1"
  if [[ -f "$path" ]]; then
    rename_one "$path"
    return
  fi
  if [[ ! -d "$path" ]]; then
    echo "skip (not file or dir): $path" >&2
    return
  fi
  # Walk children depth-first (files first, then dirs)
  while IFS= read -r -d '' entry; do
    rename_one "$entry"
  done < <(find "$path" -depth -type f \
            -not -path '*/.git/*' \
            -not -path '*/target/*' \
            -not -path '*/.build/*' \
            -not -path '*/DerivedData/*' \
            -not -path '*/node_modules/*' \
            -not -path '*/xcode-derived-lanes/*' \
            -not -path '*/xcode-derived/*' \
            -print0)
  # Then walk directories bottom-up
  while IFS= read -r -d '' entry; do
    rename_one "$entry"
  done < <(find "$path" -depth -type d \
            -not -path '*/.git*' \
            -not -path '*/target*' \
            -not -path '*/.build*' \
            -not -path '*/DerivedData*' \
            -not -path '*/node_modules*' \
            -not -path '*/xcode-derived*' \
            -print0)
}

for arg in "$@"; do
  walk_path "$arg"
done
