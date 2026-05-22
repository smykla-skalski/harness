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
        let refreshed = try await DashboardDependenciesTimeoutRacer.race(
          timeoutSeconds: DashboardDependenciesTimeoutRacer.defaultRefreshTimeoutSeconds
        ) {
          try await DashboardDependenciesRemoteLoader.refresh(
            client: client,
            request: DependencyUpdatesRefreshRequest(targets: targets)
          )
        }
        applyRefreshedItems(refreshed)
      } catch let error as DashboardDependenciesSchedulerError {
        HarnessMonitorLogger.api.warning(
          """
          Dependency targeted refresh timed out: \
          targets=\(targetIDs.count, privacy: .public) \
          error=\(String(reflecting: error), privacy: .public)
          """
        )
      } catch {
        HarnessMonitorLogger.api.warning(
          "Dependency targeted refresh failed: \(String(reflecting: error), privacy: .public)"
        )
      }
    }
  }

  func isPullRequestRefreshing(_ pullRequestID: String) -> Bool {
    routeRefreshTracker.isRefreshing(pullRequestID)
  }

  func pullRequestActionTitle(_ pullRequestID: String) -> String? {
    routeRefreshTracker.actionTitle(for: pullRequestID)
  }

  func beginRefreshing(pullRequestIDs ids: [String], actionTitle title: String? = nil) {
    var tracker = routeRefreshTracker
    tracker.begin(pullRequestIDs: ids, actionTitle: title)
    routeRefreshTracker = tracker
  }

  func endRefreshing(pullRequestIDs ids: [String]) {
    var tracker = routeRefreshTracker
    tracker.end(pullRequestIDs: ids)
    routeRefreshTracker = tracker
  }

  func pruneRefreshTrackerToLiveItems() {
    let liveIDs = Set(routeResponse.items.map(\.pullRequestID))
    var tracker = routeRefreshTracker
    tracker.prune(toLiveIDs: liveIDs)
    routeRefreshTracker = tracker
  }

  func applyRefreshedItems(_ refresh: DependencyUpdatesRefreshResponse) {
    let nextItems = applyDependencyRefresh(to: routeResponse.items, refresh: refresh)
    routeResponse = DependencyUpdatesQueryResponse(
      fetchedAt: refresh.fetchedAt,
      fromCache: routeResponse.fromCache,
      summary: DependencyUpdatesSummary(items: nextItems),
      items: nextItems
    )
    pruneRefreshTrackerToLiveItems()
    persistDependenciesRefresh(refresh)
  }
}
