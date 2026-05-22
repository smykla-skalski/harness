import HarnessMonitorKit
import SwiftUI

extension DashboardDependenciesRouteView {
  func scheduleAffectedRefresh(
    for items: [DependencyUpdateItem],
    using client: any HarnessMonitorClientProtocol
  ) {
    guard !items.isEmpty else { return }
    let targetIDs = items.map(\.pullRequestID)
    let targets = items.map(\.target)
    beginRefreshing(pullRequestIDs: targetIDs)
    Task {
      defer { endRefreshing(pullRequestIDs: targetIDs) }
      do {
        let refreshed = try await DashboardDependenciesRemoteLoader.refresh(
          client: client,
          request: DependencyUpdatesRefreshRequest(targets: targets)
        )
        applyRefreshedItems(refreshed)
      } catch {
        HarnessMonitorLogger.api.warning(
          "Dependency targeted refresh failed: \(String(reflecting: error), privacy: .public)"
        )
      }
    }
  }

  func isPullRequestRefreshing(_ pullRequestID: String) -> Bool {
    (routeRefreshingPullRequestCounts[pullRequestID] ?? 0) > 0
  }

  func beginRefreshing(pullRequestIDs ids: [String]) {
    var counts = routeRefreshingPullRequestCounts
    for id in ids {
      counts[id, default: 0] += 1
    }
    routeRefreshingPullRequestCounts = counts
  }

  func endRefreshing(pullRequestIDs ids: [String]) {
    var counts = routeRefreshingPullRequestCounts
    for id in ids {
      let next = (counts[id] ?? 0) - 1
      if next > 0 {
        counts[id] = next
      } else {
        counts.removeValue(forKey: id)
      }
    }
    routeRefreshingPullRequestCounts = counts
  }

  func applyRefreshedItems(_ refresh: DependencyUpdatesRefreshResponse) {
    let nextItems = applyDependencyRefresh(to: routeResponse.items, refresh: refresh)
    routeResponse = DependencyUpdatesQueryResponse(
      fetchedAt: refresh.fetchedAt,
      fromCache: routeResponse.fromCache,
      summary: DependencyUpdatesSummary(items: nextItems),
      items: nextItems
    )
    persistDependenciesRefresh(refresh)
  }
}
