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
    guard let data = storedValue.data(using: .utf8), !data.isEmpty else {
      routeRecentDependencyActions = [:]
      return
    }
    do {
      routeRecentDependencyActions = try JSONDecoder().decode(
        [String: DashboardDependencyActivityEntry].self,
        from: data
      )
    } catch {
      HarnessMonitorLogger.swiftui.warning(
        "Dependency action diagnostics decode failed: \(String(reflecting: error), privacy: .public)"
      )
      routeRecentDependencyActions = [:]
    }
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
    do {
      let data = try JSONEncoder().encode(limited)
      if let encoded = String(bytes: data, encoding: .utf8) {
        recentDependencyActionsStorage = encoded
      }
    } catch {
      HarnessMonitorLogger.swiftui.warning(
        "Dependency action diagnostics encode failed: \(String(reflecting: error), privacy: .public)"
      )
    }
  }

  func clearRecentDependencyActions() {
    routeRecentDependencyActions = [:]
    recentDependencyActionsStorage = ""
  }
}
