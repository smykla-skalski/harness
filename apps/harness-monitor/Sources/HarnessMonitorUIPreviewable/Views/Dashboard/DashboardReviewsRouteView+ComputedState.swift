import Foundation
import HarnessMonitorKit

extension DashboardReviewsRouteView {
  var reloadTaskKey: DashboardReviewsReloadTaskKey {
    DashboardReviewsReloadTaskKey(
      preferencesSignature: routeResolvedPreferences.cacheHash,
      isConnected: isReviewsReloadConnected(store.connectionState),
      githubDataRevision: store.contentUI.dashboard.githubDataRevision
    )
  }

  var normalizedPreferences: DashboardReviewsPreferences {
    routeResolvedPreferences.preferences
  }

  var groupMode: DashboardReviewsGroupMode {
    DashboardReviewsGroupMode(rawValue: groupModeRaw) ?? .repository
  }

  var listPresentationInput: DashboardReviewsListPresentationInput {
    let preferences = routeResolvedPreferences
    return DashboardReviewsListPresentationInput(
      items: routeResponse.items,
      itemsVersion: routeResponseItemsVersion,
      filterModeRaw: filterModeRaw,
      sortModeRaw: sortModeRaw,
      groupModeRaw: groupModeRaw,
      categoryModeRaw: categoryModeRaw,
      searchText: searchText,
      configuredRepositories: preferences.repositories,
      configuredOrganizations: preferences.organizations,
      configuredAuthors: preferences.authors,
      pinnedPullRequestIDs: routePinnedPullRequests.pullRequestIDs,
      pinnedRepositoryIDs: routePinnedRepositories.repositoryIDs,
      snoozedPullRequests: routeSnoozedPullRequests,
      needsMeOn: needsMeOn,
      dependenciesOnlyOn: dependenciesOnlyOn,
      showSnoozedOnly: showSnoozedOnly,
      viewerLogin: routeResponse.viewerLogin
    )
  }

  var presentationTaskID: DashboardReviewsPresentationTaskID {
    DashboardReviewsPresentationTaskID(
      itemsVersion: routeResponseItemsVersion,
      filterModeRaw: filterModeRaw,
      sortModeRaw: sortModeRaw,
      groupModeRaw: groupModeRaw,
      categoryModeRaw: categoryModeRaw,
      searchText: searchText,
      preferencesSignature: routeResolvedPreferences.cacheHash,
      pinnedPullRequestIDs: routePinnedPullRequests.pullRequestIDs,
      pinnedRepositoryIDs: routePinnedRepositories.repositoryIDs,
      snoozedPullRequests: routeSnoozedPullRequests,
      needsMeOn: needsMeOn,
      dependenciesOnlyOn: dependenciesOnlyOn,
      showSnoozedOnly: showSnoozedOnly,
      viewerLogin: routeResponse.viewerLogin
    )
  }

  var presentationSelectionID: DashboardReviewsPresentationSelectionID {
    DashboardReviewsPresentationSelectionID(
      selectedIDs: routeSelectedIDs,
      persistedPrimarySelectionID: persistedPrimarySelectionID,
      sortModeRaw: sortModeRaw
    )
  }

  var filteredItems: [ReviewItem] {
    routeCachedPresentation.filteredItems
  }

  var groupedItems: [DashboardReviewsRepositoryGroup] {
    routeCachedPresentation.groupedItems
  }

  var selectedItems: [ReviewItem] {
    routeCachedPresentation.selectedItems
  }

  var primaryDetailItem: ReviewItem? {
    routeCachedPresentation.primaryDetailItem
  }

  var relativeUpdatedLabels: [String: String] {
    routeCachedPresentation.relativeUpdatedLabels
  }
}
