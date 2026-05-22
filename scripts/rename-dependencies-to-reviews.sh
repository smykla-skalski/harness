#!/usr/bin/env bash
# Mechanical text-rewrite for the Dependencies → Reviews feature rename.
#
# Usage: rename-dependencies-to-reviews.sh <path-or-file> [more-paths...]
#
# Operates on .rs .swift .toml .md .json .yaml .yml .sh files under each
# given path. Skips .git, target, .build, DerivedData, node_modules.
#
# Strategy:
#   1) Protect known legitimate package / DI / docker / Swift-Concurrency
#      tokens with one-shot sentinels so the rename never touches them.
#   2) Protect DependencyUpdateReview with a special sentinel so it
#      renames to PullRequestReview (avoids the Review.Review collision).
#   3) Apply longest-substring-first rename rules for every feature form
#      (PascalCase / camelCase / snake_case / kebab-case / SCREAMING).
#   4) Restore sentinels to their final value.
#
# Files explicitly excluded (must keep historical class names for SwiftData
# migration):
#   - apps/harness-monitor-macos/Sources/HarnessMonitorKit/Persistence/HarnessMonitorSchemaV21.swift
#   - apps/harness-monitor-macos/Sources/HarnessMonitorKit/Persistence/HarnessMonitorSchemaV*toV*.swift (any old migration shims)
#   - the rename / validator scripts themselves
set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage: $0 <path-or-file> [more-paths...]

Rewrites Dependencies-feature identifiers to Reviews-feature names
across .rs .swift .toml .md .json .yaml .yml .sh files.

Skipped paths (historical / tool-self):
  - **/HarnessMonitorSchemaV21.swift
  - **/HarnessMonitorMigrationV*.swift  (preserves old-side names for migration)
  - scripts/rename-dependencies-to-reviews.sh
  - scripts/validate-reviews-rename.sh
  - scripts/.rename-allow.txt
EOF
  exit 64
}

[[ $# -ge 1 ]] || usage

# ----- Collect file list -----
collect_files() {
  local arg
  for arg in "$@"; do
    if [[ -d "$arg" ]]; then
      find "$arg" -type f \( \
        -name '*.rs' -o -name '*.swift' -o -name '*.toml' \
        -o -name '*.md' -o -name '*.json' -o -name '*.yaml' \
        -o -name '*.yml' -o -name '*.sh' \
        \) \
        -not -path '*/.git/*' \
        -not -path '*/target/*' \
        -not -path '*/.build/*' \
        -not -path '*/DerivedData/*' \
        -not -path '*/node_modules/*' \
        -not -path '*/xcode-derived-lanes/*' \
        -not -path '*/xcode-derived/*' \
        -not -name 'HarnessMonitorSchemaV21.swift' \
        -not -name 'HarnessMonitorMigrationV*.swift' \
        -not -name 'rename-dependencies-to-reviews.sh' \
        -not -name 'validate-reviews-rename.sh' \
        -not -name '.rename-allow.txt'
    elif [[ -f "$arg" ]]; then
      case "$(basename "$arg")" in
        HarnessMonitorSchemaV21.swift|HarnessMonitorMigrationV*.swift) ;;
        rename-dependencies-to-reviews.sh|validate-reviews-rename.sh|.rename-allow.txt) ;;
        *) echo "$arg" ;;
      esac
    fi
  done
}

# ----- The rename perl script (kept verbatim for inspection) -----
# shellcheck disable=SC2016
# Intentional single quotes: PERL_SCRIPT is the literal perl source, not a shell template.
PERL_SCRIPT='
# 1) Sentinel-protect legitimate non-feature occurrences
s/\bRunDependencies\b/__HRH_KEEP_RunDependencies__/g;
s/\bServiceDependency\b/__HRH_KEEP_ServiceDependency__/g;
s/\bTargetDependency\b/__HRH_KEEP_TargetDependency__/g;
s/\bkitDependencies\b/__HRH_KEEP_kitDependencies__/g;
s/\bmonitorAppDependencies\b/__HRH_KEEP_monitorAppDependencies__/g;
s/\[dependencies\]/__HRH_KEEP_cargo_dependencies_section__/g;
s/\[dev-dependencies\]/__HRH_KEEP_cargo_dev_dependencies_section__/g;
s/\[build-dependencies\]/__HRH_KEEP_cargo_build_dependencies_section__/g;
s/\[workspace\.dependencies\]/__HRH_KEEP_cargo_workspace_dependencies__/g;
s/\bdependsOn\s*:/__HRH_KEEP_dependsOn__:/g;
s/\bdepends_on\b/__HRH_KEEP_depends_on__/g;
s/\bdepends\s+on\b/__HRH_KEEP_depends_on_phrase__/gi;
s/\bDependencyInject(or|ion)\b/__HRH_KEEP_DependencyInject$1__/g;
# Case-preserving variants for common comment phrases (capital first so /g rules below do not lowercase them)
s/Injected\s+dependency/__HRH_KEEP_Injected_dependency__/g;
s/Circular\s+dependency/__HRH_KEEP_Circular_dependency__/g;
s/External\s+dependency/__HRH_KEEP_External_dependency__/g;
s/Runtime\s+dependency/__HRH_KEEP_Runtime_dependency__/g;
s/Package\s+dependency/__HRH_KEEP_Package_dependency__/g;
s/Build\s+dependency/__HRH_KEEP_Build_dependency__/g;
s/Transitive\s+dependency/__HRH_KEEP_Transitive_dependency__/g;
s/Dev\s+dependency/__HRH_KEEP_Dev_dependency__/g;
s/Task\s+dependency/__HRH_KEEP_Task_dependency__/g;
s/Dependency\s+injection/__HRH_KEEP_Dependency_injection__/g;
s/injected\s+dependency/__HRH_KEEP_injected_dependency__/g;
s/circular\s+dependency/__HRH_KEEP_circular_dependency__/g;
s/external\s+dependency/__HRH_KEEP_external_dependency__/g;
s/runtime\s+dependency/__HRH_KEEP_runtime_dependency__/g;
s/package\s+dependency/__HRH_KEEP_package_dependency__/g;
s/build\s+dependency/__HRH_KEEP_build_dependency__/g;
s/transitive\s+dependency/__HRH_KEEP_transitive_dependency__/g;
s/dev\s+dependency/__HRH_KEEP_dev_dependency__/g;
s/task\s+dependency/__HRH_KEEP_task_dependency__/g;
s/dependency\s+injection/__HRH_KEEP_dependency_injection__/g;
# SPM literal form
s/\bdependencies:\s*\[/__HRH_KEEP_spm_dependencies_array__: \[/g;

# 2) Special-case: DependencyUpdateReview becomes PullRequestReview
s/\bDependencyUpdateReview\b/__HRH_RENAME_PullRequestReview__/g;

# 3) Longest-first compound prefixes
s/HarnessMonitorDependenciesTimelineModels/HarnessMonitorReviewsTimelineModels/g;
s/HarnessMonitorDependencyActionPreviewModels/HarnessMonitorReviewActionPreviewModels/g;
s/HarnessMonitorDependencyThreadResolveModels/HarnessMonitorReviewThreadResolveModels/g;
s/HarnessMonitorDependenciesRefreshMerge/HarnessMonitorReviewsRefreshMerge/g;
s/HarnessMonitorDependencyActionModels/HarnessMonitorReviewActionModels/g;
s/HarnessMonitorDependenciesClientProtocol/HarnessMonitorReviewsClientProtocol/g;
s/HarnessMonitorDependenciesExtensions/HarnessMonitorReviewsExtensions/g;
s/HarnessMonitorDependenciesEnums/HarnessMonitorReviewsEnums/g;
s/HarnessMonitorDependenciesModels/HarnessMonitorReviewsModels/g;
s/HarnessMonitorDependencies/HarnessMonitorReviews/g;
s/HarnessMonitorDependency/HarnessMonitorReview/g;
s/DashboardDependencies/DashboardReviews/g;
s/DashboardDependency/DashboardReview/g;
s/SettingsDependencies/SettingsReviews/g;
s/SettingsDependency/SettingsReview/g;
s/DependenciesPreferences/ReviewsPreferences/g;
s/DependencyCommands/ReviewCommands/g;
s/OpenAnythingDashboardDependencyRegistry/OpenAnythingDashboardReviewRegistry/g;

# CachedDependency*
s/CachedDependencyUpdatesSnapshot/CachedReviewsSnapshot/g;
s/CachedDependencyUpdatesRepoSyncState/CachedReviewsRepoSyncState/g;
s/CachedDependencyUpdateFilesSummary/CachedReviewFilesSummary/g;
s/CachedDependencyUpdateFileViewedState/CachedReviewFileViewedState/g;
s/CachedDependencyUpdateFile/CachedReviewFile/g;
s/CachedDependencyRepositoryLabels/CachedReviewRepositoryLabels/g;
s/CachedDependencyLabelUsage/CachedReviewLabelUsage/g;
s/CachedDependencyUpdates/CachedReviews/g;
s/CachedDependencyUpdate/CachedReview/g;
s/CachedDependency/CachedReview/g;

# DependencyUpdates* / DependencyUpdate*
s/DependencyUpdatesGitHubClient/ReviewsGitHubClient/g;
s/DependencyUpdatesCapabilitiesResponse/ReviewsCapabilitiesResponse/g;
s/DependencyUpdatesRepoSyncStateCache/ReviewsRepoSyncStateCache/g;
s/DependencyUpdateFilesViewModel/ReviewFilesViewModel/g;
s/DependencyUpdateTimelineViewModel/ReviewTimelineViewModel/g;
s/DependencyUpdateLocalCloneProgress/ReviewLocalCloneProgress/g;
s/DependencyUpdateFilePatchStore/ReviewFilePatchStore/g;
s/DependencyUpdateImageDecoder/ReviewImageDecoder/g;
s/DependencyUpdateBodyStore/ReviewBodyStore/g;
s/DependencyUpdateAvatarCache/ReviewAvatarCache/g;
s/DependencyUpdateFilesCache/ReviewFilesCache/g;
s/DependencyUpdateBot/ReviewBot/g;
s/DependencyUpdateFile/ReviewFile/g;
s/DependencyUpdateItem/ReviewItem/g;
s/DependencyUpdateCheck/ReviewCheck/g;
s/DependencyUpdateTarget/ReviewTarget/g;
s/DependencyUpdateRepositoryLabel/ReviewRepositoryLabel/g;
s/DependencyUpdateTimelineEntry/ReviewTimelineEntry/g;
s/DependencyUpdateAvatar/ReviewAvatar/g;
s/DependencyUpdatesQueryRequest/ReviewsQueryRequest/g;
s/DependencyUpdatesQueryResponse/ReviewsQueryResponse/g;
s/DependencyUpdatesRepositoryCatalogRequest/ReviewsRepositoryCatalogRequest/g;
s/DependencyUpdatesApproveRequest/ReviewsApproveRequest/g;
s/DependencyUpdatesMergeRequest/ReviewsMergeRequest/g;
s/DependencyUpdatesRerunChecksRequest/ReviewsRerunChecksRequest/g;
s/DependencyUpdatesLabelRequest/ReviewsLabelRequest/g;
s/DependencyUpdatesAutoRequest/ReviewsAutoRequest/g;
s/DependencyUpdatesCommentRequest/ReviewsCommentRequest/g;
s/DependencyUpdatesActionResponse/ReviewsActionResponse/g;
s/DependencyUpdatesCacheClearResponse/ReviewsCacheClearResponse/g;
s/DependencyUpdatesRefreshRequest/ReviewsRefreshRequest/g;
s/DependencyUpdatesRefreshResponse/ReviewsRefreshResponse/g;
s/DependencyUpdatesBodyUpdateRequest/ReviewsBodyUpdateRequest/g;
s/DependencyUpdatesBodyUpdateResponse/ReviewsBodyUpdateResponse/g;
s/DependencyUpdatesBodyUpdateOutcome/ReviewsBodyUpdateOutcome/g;
s/DependencyUpdatesBodyRequest/ReviewsBodyRequest/g;
s/DependencyUpdatesBodyResponse/ReviewsBodyResponse/g;
s/DependencyUpdatesFilesListRequest/ReviewsFilesListRequest/g;
s/DependencyUpdatesFilesListResponse/ReviewsFilesListResponse/g;
s/DependencyUpdatesCache/ReviewsCache/g;
s/DependencyUpdates/Reviews/g;
s/DependencyUpdate/Review/g;

# Snake / kebab / SCREAMING / camel forms
s/dependency_updates_files_local_clones_/reviews_files_local_clones_/g;
s/dependency_updates_files_/reviews_files_/g;
s/dependency_updates_/reviews_/g;
s/dependency_update_/review_/g;
s/dependency-updates/reviews/g;
s/dependency_updates/reviews/g;
s/dependencyUpdatesLocalCloneProgress/reviewsLocalCloneProgress/g;
s/dependencyUpdatesRepositoryCatalog/reviewsRepositoryCatalog/g;
s/dependencyUpdatesReviewThreadsResolve/reviewsReviewThreadsResolve/g;
s/dependencyUpdates/reviews/g;
s/dependencyUpdate/review/g;
s/DEPENDENCY_UPDATES_/REVIEWS_/g;
s/DEPENDENCY_UPDATE_/REVIEW_/g;

# Feature-specific identifiers
s/DependencyPullRequestTimelineNodeBuilder/ReviewPullRequestTimelineNodeBuilder/g;
s/DependencyFilesPerf/ReviewFilesPerf/g;
s/DependencyTimelinePerf/ReviewTimelinePerf/g;

# Route literals
s|/v1/dependency-updates|/v1/reviews|g;

# Perf-scenario rawValues
s/"dependencies-settings"/"reviews-settings"/g;
s/"dependency-detail-timeline/"review-detail-timeline/g;

# UserDefaults keys
s/"dashboard\.dependencies\./"dashboard.reviews./g;
s/"dependencies\./"reviews./g;

# camelCase variable / identifier prefixes (literals + a11y ids + var names)
s/\bsettingsDependencies/settingsReviews/g;
s/\bsettingsDependency/settingsReview/g;
s/\bdashboardDependencies/dashboardReviews/g;
s/\bdashboardDependency/dashboardReview/g;
s/"settingsDependencies/"settingsReviews/g;
s/"settingsDependency/"settingsReview/g;
s/"dashboardDependencies/"dashboardReviews/g;
s/"dashboardDependency/"dashboardReview/g;

# User-facing SwiftUI display strings
s/Text\("Dependencies"\)/Text("Reviews")/g;
s/Label\("Dependencies"/Label("Reviews"/g;
s/Button\("Dependencies"/Button("Reviews"/g;
s/LabeledContent\("Dependencies"/LabeledContent("Reviews"/g;
s/title:\s*"Dependencies"/title: "Reviews"/g;
s/sectionTitle:\s*"Dependencies"/sectionTitle: "Reviews"/g;
s/name:\s*"Dependencies"/name: "Reviews"/g;
s/label:\s*"Dependencies"/label: "Reviews"/g;
s/navigationTitle\("Dependencies"\)/navigationTitle("Reviews")/g;

# 4) Restore sentinels
s/__HRH_KEEP_RunDependencies__/RunDependencies/g;
s/__HRH_KEEP_ServiceDependency__/ServiceDependency/g;
s/__HRH_KEEP_TargetDependency__/TargetDependency/g;
s/__HRH_KEEP_kitDependencies__/kitDependencies/g;
s/__HRH_KEEP_monitorAppDependencies__/monitorAppDependencies/g;
s/__HRH_KEEP_cargo_dependencies_section__/[dependencies]/g;
s/__HRH_KEEP_cargo_dev_dependencies_section__/[dev-dependencies]/g;
s/__HRH_KEEP_cargo_build_dependencies_section__/[build-dependencies]/g;
s/__HRH_KEEP_cargo_workspace_dependencies__/[workspace.dependencies]/g;
s/__HRH_KEEP_dependsOn__/dependsOn/g;
s/__HRH_KEEP_depends_on__/depends_on/g;
s/__HRH_KEEP_depends_on_phrase__/depends on/g;
s/__HRH_KEEP_dependency_injection__/dependency injection/g;
s/__HRH_KEEP_circular_dependency__/circular dependency/g;
s/__HRH_KEEP_injected_dependency__/injected dependency/g;
s/__HRH_KEEP_external_dependency__/external dependency/g;
s/__HRH_KEEP_runtime_dependency__/runtime dependency/g;
s/__HRH_KEEP_package_dependency__/package dependency/g;
s/__HRH_KEEP_build_dependency__/build dependency/g;
s/__HRH_KEEP_transitive_dependency__/transitive dependency/g;
s/__HRH_KEEP_dev_dependency__/dev dependency/g;
s/__HRH_KEEP_task_dependency__/task dependency/g;
s/__HRH_KEEP_DependencyInjector__/DependencyInjector/g;
s/__HRH_KEEP_DependencyInjection__/DependencyInjection/g;
s/__HRH_KEEP_Injected_dependency__/Injected dependency/g;
s/__HRH_KEEP_Circular_dependency__/Circular dependency/g;
s/__HRH_KEEP_External_dependency__/External dependency/g;
s/__HRH_KEEP_Runtime_dependency__/Runtime dependency/g;
s/__HRH_KEEP_Package_dependency__/Package dependency/g;
s/__HRH_KEEP_Build_dependency__/Build dependency/g;
s/__HRH_KEEP_Transitive_dependency__/Transitive dependency/g;
s/__HRH_KEEP_Dev_dependency__/Dev dependency/g;
s/__HRH_KEEP_Task_dependency__/Task dependency/g;
s/__HRH_KEEP_Dependency_injection__/Dependency injection/g;
s/__HRH_KEEP_spm_dependencies_array__: \[/dependencies: [/g;
s/__HRH_RENAME_PullRequestReview__/PullRequestReview/g;
'

count=0
mapfile -t FILES < <(collect_files "$@")
for f in "${FILES[@]}"; do
  [[ -z "$f" ]] && continue
  perl -i -CSD -pe "$PERL_SCRIPT" "$f"
  count=$((count + 1))
done

echo "Rewrote $count files."
