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
      totalCheckCount: item.checks.count,
      capabilities: routeDependencyCapabilities
    )
  }

  func recordDependencyActionResponse(
    _ response: DependencyUpdatesActionResponse,
    title: String,
    items: [DependencyUpdateItem]
  ) {
    let resultsByTarget = Dictionary(grouping: response.results) { result in
      DashboardDependencyActionResultKey(repository: result.repository, number: result.number)
    }
    var actions = routeRecentDependencyActions
    for item in items {
      let targetKey = DashboardDependencyActionResultKey(
        repository: item.repository,
        number: item.number
      )
      actions[item.pullRequestID] = DashboardDependencyActivityEntry.success(
        title: title,
        response: response,
        results: resultsByTarget[targetKey] ?? []
      )
    }
    routeRecentDependencyActions = actions
    persistRecentDependencyActions()
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
    persistRecentDependencyActions()
  }

  func syncRecentDependencyActionsFromStorage(_ storedValue: String) {
    guard !storedValue.isEmpty else {
      routeRecentDependencyActions = [:]
      return
    }

    guard
      let decoded = DashboardDependenciesStorageCodec.decode(
        [String: DashboardDependencyActivityEntry].self,
        from: storedValue
      )
    else {
      HarnessMonitorLogger.swiftui.warning(
        "Dependency action diagnostics decode failed"
      )
      routeRecentDependencyActions = [:]
      return
    }
    routeRecentDependencyActions = decoded
  }

  func persistRecentDependencyActions() {
    let limited = Dictionary(
      uniqueKeysWithValues:
        routeRecentDependencyActions
        .sorted { lhs, rhs in lhs.value.recordedAt > rhs.value.recordedAt }
        .prefix(80)
        .map { ($0.key, $0.value) }
    )
    routeRecentDependencyActions = limited
    let encoded = DashboardDependenciesStorageCodec.encodeToString(limited)
    if encoded.isEmpty {
      HarnessMonitorLogger.swiftui.warning(
        "Dependency action diagnostics encode failed"
      )
      return
    }
    recentDependencyActionsStorage = encoded
  }

  func clearRecentDependencyActions() {
    routeRecentDependencyActions = [:]
    recentDependencyActionsStorage = ""
  }
}

private struct DashboardDependencyActionResultKey: Hashable {
  let repository: String
  let number: UInt64
}
