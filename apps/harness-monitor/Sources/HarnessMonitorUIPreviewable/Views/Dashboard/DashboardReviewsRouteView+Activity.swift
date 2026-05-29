import Foundation
import HarnessMonitorKit

extension DashboardReviewsRouteView {
  func activitySnapshot(for item: ReviewItem) -> DashboardReviewActivitySnapshot {
    DashboardReviewActivitySnapshot(
      pullRequestID: item.pullRequestID,
      isRefreshing: isPullRequestRefreshing(item.pullRequestID),
      actionTitle: pullRequestActionTitle(item.pullRequestID),
      fetchedAt: routeResponse.fetchedAt,
      fromCache: routeResponse.fromCache,
      lastAction: routeRecentReviewActions[item.pullRequestID],
      policyStatus: routeReviewPolicyStatusByPullRequestID[item.pullRequestID],
      missingCheckRunURLCount: item.checks.count { $0.detailsWebURL == nil },
      totalCheckCount: item.checks.count,
      capabilities: routeReviewCapabilities
    )
  }

  func recordReviewActionResponse(
    _ response: ReviewsActionResponse,
    title: String,
    items: [ReviewItem]
  ) {
    let resultsByTarget = Dictionary(grouping: response.results) { result in
      DashboardReviewActionResultKey(repository: result.repository, number: result.number)
    }
    var actions = routeRecentReviewActions
    for item in items {
      let targetKey = DashboardReviewActionResultKey(
        repository: item.repository,
        number: item.number
      )
      actions[item.pullRequestID] = DashboardReviewActivityEntry.success(
        title: title,
        response: response,
        results: resultsByTarget[targetKey] ?? []
      )
    }
    routeRecentReviewActions = actions
    persistRecentReviewActions()
  }

  func recordReviewActionFailure(
    _ error: Error,
    title: String,
    items: [ReviewItem]
  ) {
    var actions = routeRecentReviewActions
    for item in items {
      actions[item.pullRequestID] = DashboardReviewActivityEntry.failure(
        title: title,
        error: error
      )
    }
    routeRecentReviewActions = actions
    persistRecentReviewActions()
  }

  func recordReviewPolicyOutcomes(
    _ outcomes: [DashboardReviewsAutoPolicyOutcome],
    title: String
  ) {
    var actions = routeRecentReviewActions
    for outcome in outcomes {
      actions[outcome.item.pullRequestID] = outcome.activityEntry(title: title)
    }
    routeRecentReviewActions = actions
    persistRecentReviewActions()
  }

  func syncRecentReviewActionsFromStorage(_ storedValue: String) {
    guard !storedValue.isEmpty else {
      routeRecentReviewActions = [:]
      return
    }

    guard
      let decoded = DashboardReviewsStorageCodec.decode(
        [String: DashboardReviewActivityEntry].self,
        from: storedValue
      )
    else {
      HarnessMonitorLogger.swiftui.warning(
        "Review action diagnostics decode failed"
      )
      routeRecentReviewActions = [:]
      return
    }
    routeRecentReviewActions = decoded
  }

  func persistRecentReviewActions() {
    let limited = Dictionary(
      uniqueKeysWithValues:
        routeRecentReviewActions
        .sorted { lhs, rhs in lhs.value.recordedAt > rhs.value.recordedAt }
        .prefix(80)
        .map { ($0.key, $0.value) }
    )
    routeRecentReviewActions = limited
    let encoded = DashboardReviewsStorageCodec.encodeToString(limited)
    if encoded.isEmpty {
      HarnessMonitorLogger.swiftui.warning(
        "Review action diagnostics encode failed"
      )
      return
    }
    recentReviewActionsStorage = encoded
  }

  func clearRecentReviewActions() {
    routeRecentReviewActions = [:]
    recentReviewActionsStorage = ""
  }
}

private struct DashboardReviewActionResultKey: Hashable {
  let repository: String
  let number: UInt64
}
