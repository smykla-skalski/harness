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
    let droppedIDs = Set(refresh.missingPullRequestIDs)
    let openItemsByID: [String: DependencyUpdateItem] = Dictionary(
      uniqueKeysWithValues: refresh.items
        .filter { $0.state == .open }
        .map { ($0.pullRequestID, $0) }
    )
    let closedIDs = Set(
      refresh.items.filter { $0.state != .open }.map(\.pullRequestID)
    )
    let nextItems = response.items.compactMap { item -> DependencyUpdateItem? in
      if droppedIDs.contains(item.pullRequestID) || closedIDs.contains(item.pullRequestID) {
        return nil
      }
      return openItemsByID[item.pullRequestID] ?? item
    }
    response = DependencyUpdatesQueryResponse(
      fetchedAt: refresh.fetchedAt,
      fromCache: response.fromCache,
      summary: DependencyUpdatesSummary(items: nextItems),
      items: nextItems
    )
  }
}
