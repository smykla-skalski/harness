import HarnessMonitorKit
import SwiftUI

extension DashboardDependenciesRouteView {
  func scheduleAffectedRefresh(
    for items: [DependencyUpdateItem],
    using client: any HarnessMonitorClientProtocol
  ) {
    guard !items.isEmpty else { return }
    let targetIDs = items.map(\.pullRequestID)
    let coversFullCatalog =
      !response.items.isEmpty
      && Set(targetIDs) == Set(response.items.map(\.pullRequestID))
    if coversFullCatalog {
      Task { await reload(forceRefresh: true, backgroundRefresh: true) }
      return
    }
    let targets = items.map(\.target)
    refreshingPullRequestIDs.formUnion(targetIDs)
    Task {
      defer { refreshingPullRequestIDs.subtract(targetIDs) }
      do {
        let refreshed = try await client.refreshDependencyUpdates(
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

  func applyRefreshedItems(_ refresh: DependencyUpdatesRefreshResponse) {
    let nextItems = applyDependencyRefresh(to: response.items, refresh: refresh)
    response = DependencyUpdatesQueryResponse(
      fetchedAt: refresh.fetchedAt,
      fromCache: response.fromCache,
      summary: DependencyUpdatesSummary(items: nextItems),
      items: nextItems
    )
  }
}
