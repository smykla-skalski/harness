import Foundation
import HarnessMonitorKit

extension DashboardDependenciesRouteView {
  func activitySnapshot(for item: DependencyUpdateItem) -> DashboardDependencyActivitySnapshot {
    DashboardDependencyActivitySnapshot(
      pullRequestID: item.pullRequestID,
      isRefreshing: isPullRequestRefreshing(item.pullRequestID),
      actionTitle: pullRequestActionTitle(item.pullRequestID),
      fetchedAt: routeResponse.fetchedAt,
      fromCache: routeResponse.fromCache,
      lastAction: routeRecentDependencyActions[item.pullRequestID],
      missingCheckRunURLCount: item.checks.count { $0.detailsWebURL == nil },
      totalCheckCount: item.checks.count
    )
  }

  func recordDependencyActionResponse(
    _ response: DependencyUpdatesActionResponse,
    title: String,
    items: [DependencyUpdateItem]
  ) {
    var actions = routeRecentDependencyActions
    for item in items {
      let matchingResults = response.results.filter {
        $0.repository == item.repository && $0.number == item.number
      }
      actions[item.pullRequestID] = DashboardDependencyActivityEntry.success(
        title: title,
        response: response,
        results: matchingResults
      )
    }
    routeRecentDependencyActions = actions
  }

  func recordDependencyActionFailure(
    _ error: Error,
    title: String,
    items: [DependencyUpdateItem]
  ) {
    var actions = routeRecentDependencyActions
    for item in items {
      actions[item.pullRequestID] = DashboardDependencyActivityEntry.failure(
        title: title,
        error: error
      )
    }
    routeRecentDependencyActions = actions
  }
}
