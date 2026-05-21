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
      !routeResponse.items.isEmpty
      && Set(targetIDs) == Set(routeResponse.items.map(\.pullRequestID))
    if coversFullCatalog {
      schedulerForceRefreshAll()
      return
    }
    let targets = items.map(\.target)
    routeRefreshingPullRequestIDs.formUnion(targetIDs)
    Task {
      defer { routeRefreshingPullRequestIDs.subtract(targetIDs) }
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
