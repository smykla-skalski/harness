import HarnessMonitorKit

extension DashboardReviewsRouteView {
  func performMutation(
    _ title: String,
    items: [ReviewItem],
    githubAction: ReviewActionKind,
    githubRevisionCount: UInt64,
    onSuccess: @MainActor () -> Void = {},
    operation:
      @Sendable @escaping (any HarnessMonitorClientProtocol) async throws
      -> ReviewsActionResponse
  ) async {
    guard !items.isEmpty else { return }
    guard let client = store.apiClient else { return }
    let githubMutationToken = beginTargetedGitHubMutation(
      action: githubAction,
      expectedRevisionCount: githubRevisionCount
    )
    let trackedIDs = items.map(\.pullRequestID)
    beginRefreshing(pullRequestIDs: trackedIDs, actionTitle: title)
    defer {
      endRefreshing(pullRequestIDs: trackedIDs)
    }
    do {
      let response = try await DashboardReviewsTimeoutRacer.race(
        timeoutSeconds: DashboardReviewsTimeoutRacer.defaultMutationTimeoutSeconds
      ) {
        try await operation(client)
      }
      recordReviewActionResponse(response, title: title, items: items)
      presentMutationFeedback(response, title: title, items: items)
      onSuccess()
      let confirmedGitHubMutationToken = await confirmTargetedGitHubMutation(
        githubMutationToken,
        appliedRevisionCount:
          dashboardReviewsMutationFullyApplied(
            response,
            expectedResultCount: items.count
          ) ? githubRevisionCount : nil,
        using: client
      )
      scheduleAffectedRefresh(
        for: items,
        using: client,
        githubMutationToken: confirmedGitHubMutationToken
      )
    } catch {
      targetedGitHubMutationFailed(githubMutationToken)
      recordReviewActionFailure(error, title: title, items: items)
      store.presentFailureFeedback(dashboardReviewsErrorMessage(for: error))
    }
  }

  private func presentMutationFeedback(
    _ response: ReviewsActionResponse,
    title: String,
    items: [ReviewItem]
  ) {
    let feedback = dashboardReviewsActionFeedback(
      title: title,
      items: items,
      response: response
    )
    switch feedback.severity {
    case .success:
      store.presentSuccessFeedback(feedback.message)
    case .failure:
      store.presentFailureFeedback(feedback.message)
    case .warning, .undoable, .activity:
      store.toast.presentWarning(feedback.message)
    }
  }
}
