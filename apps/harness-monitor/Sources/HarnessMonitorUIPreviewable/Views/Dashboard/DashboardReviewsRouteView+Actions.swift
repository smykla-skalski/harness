import HarnessMonitorIntents
import HarnessMonitorKit
import SwiftUI

extension DashboardReviewsRouteView {
  func reload(forceRefresh: Bool, backgroundRefresh: Bool = false) async {
    let cacheApplied = hydrateReviewsFromCacheIfNeeded()
    guard store.apiClient != nil else {
      switch dashboardReviewsMissingClientState(
        backgroundRefresh: backgroundRefresh,
        connectionState: store.connectionState
      ) {
      case .ignore:
        return
      case .loading:
        routeIsLoading = true
        routeErrorMessage = nil
        return
      case .error(let message):
        routeIsLoading = false
        routeErrorMessage = message
        return
      }
    }
    if backgroundRefresh {
      routeIsBackgroundRefreshing = true
    } else {
      routeIsLoading = true
      routeErrorMessage = nil
    }
    defer {
      if backgroundRefresh {
        routeIsBackgroundRefreshing = false
      } else {
        routeIsLoading = false
      }
    }
    if let client = store.apiClient {
      await loadReviewCapabilitiesIfNeeded(client: client)
    }
    await startScheduler(
      forceRefreshAll: dashboardReviewsShouldForceSchedulerRefresh(
        explicitForceRefresh: forceRefresh,
        cacheApplied: cacheApplied,
        response: routeResponse
      )
    )
  }

  func clearCacheAndReload() async {
    guard let client = store.apiClient else { return }
    do {
      let cleared = try await DashboardReviewsTimeoutRacer.race(
        timeoutSeconds: DashboardReviewsTimeoutRacer.defaultMutationTimeoutSeconds
      ) {
        try await client.clearReviewsCache()
      }
      store.presentSuccessFeedback(
        "Cleared \(cleared.clearedEntries) cached review query bucket(s)"
      )
      clearRecentReviewActions()
      await reload(forceRefresh: true)
    } catch {
      store.presentFailureFeedback(error.localizedDescription)
    }
  }

  func approve(items: [ReviewItem]) async {
    let actionableItems = items.filter(\.canAttemptManualApproval)
    HarnessMonitorIntentDonations.donateApprove(items: actionableItems)
    await performMutation("Approving", items: actionableItems) { client in
      try await client.approveReviews(
        request: ReviewsApproveRequest(
          targets: actionableItems.map(\.target),
          source: .direct
        )
      )
    }
  }

  func merge(items: [ReviewItem]) async {
    let actionableItems = items.filter(\.canAttemptManualMerge)
    HarnessMonitorIntentDonations.donateMerge(items: actionableItems)
    let nextID = nextSelectionID(after: actionableItems)
    await performMutation(
      "Merging",
      items: actionableItems,
      onSuccess: {
        if let nextID {
          routeSelectedIDs = [nextID]
        }
      },
      operation: { client in
        try await client.mergeReviews(
          request: ReviewsMergeRequest(
            targets: actionableItems.map(\.target),
            method: normalizedPreferences.mergeMethod
          )
        )
      }
    )
  }

  func nextSelectionID(after items: [ReviewItem]) -> String? {
    let mergedIDs = Set(items.map(\.pullRequestID))
    let list = filteredItems
    guard
      let lastMergedIndex = list.lastIndex(where: { mergedIDs.contains($0.pullRequestID) })
    else {
      return nil
    }
    return list[(lastMergedIndex + 1)...]
      .first(where: { !mergedIDs.contains($0.pullRequestID) })?
      .pullRequestID
  }

  func rerunChecks(items: [ReviewItem]) async {
    let actionableItems = items.filter(\.canAttemptRerunChecks)
    HarnessMonitorIntentDonations.donateRerunChecks(items: actionableItems)
    await performMutation("Rerunning", items: actionableItems) { client in
      try await client.rerunReviewChecks(
        request: ReviewsRerunChecksRequest(targets: actionableItems.map(\.rerunTarget))
      )
    }
  }

  func rerunCheck(_ check: ReviewCheck, for item: ReviewItem) async {
    guard item.viewerCanUpdate else {
      store.toast.presentWarning(
        DashboardReviewsDisabledReason.rerunReason(for: [item])
          ?? "Current GitHub token cannot update this pull request"
      )
      return
    }
    guard check.isRerunnable, let checkSuiteID = check.checkSuiteID else {
      store.toast.presentWarning(
        check.rerunUnavailableReason ?? "This check cannot be rerun from the dashboard"
      )
      return
    }
    let target = ReviewTarget(
      pullRequestID: item.pullRequestID,
      repositoryID: item.repositoryID,
      repository: item.repository,
      number: item.number,
      url: item.url,
      state: item.state,
      isDraft: item.isDraft,
      headSha: item.headSha,
      mergeable: item.mergeable,
      reviewStatus: item.reviewStatus,
      checkStatus: item.checkStatus,
      policyBlocked: item.policyBlocked,
      requiredFailedCheckNames: item.requiredFailedCheckNames,
      viewerCanMergeAsAdmin: item.viewerCanMergeAsAdmin,
      checkSuiteIDs: [checkSuiteID],
      viewerCanUpdate: item.viewerCanUpdate
    )
    await performMutation("Rerunning \(check.name)", items: [item]) { client in
      try await client.rerunReviewChecks(
        request: ReviewsRerunChecksRequest(targets: [target])
      )
    }
  }

  func refresh(items: [ReviewItem]) {
    guard let client = store.apiClient, !items.isEmpty else { return }
    scheduleAffectedRefresh(for: items, using: client)
  }

  func addLabel(_ label: String, to items: [ReviewItem]) async {
    let actionableItems = items.filter(\.canAddReviewLabel)
    HarnessMonitorIntentDonations.donateAddLabel(label, to: actionableItems)
    await performMutation(
      "Labeling",
      items: actionableItems,
      onSuccess: { recordLabelUsage(label, items: actionableItems) },
      operation: { client in
        try await client.addReviewLabel(
          request: ReviewsLabelRequest(
            targets: actionableItems.map(\.target),
            label: label
          )
        )
      }
    )
  }

  func reRequestReview(from reviewer: String, on item: ReviewItem) async {
    let trimmed = reviewer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    await performMutation("Re-requesting review from @\(trimmed)", items: [item]) { client in
      try await client.reRequestReview(
        request: ReviewsRequestReviewRequest(
          targets: [item.target],
          reviewerLogin: trimmed
        )
      )
    }
  }

  func auto(items: [ReviewItem]) async {
    guard !items.isEmpty else { return }
    guard let client = store.apiClient else { return }
    let trackedIDs = items.map(\.pullRequestID)
    beginRefreshing(pullRequestIDs: trackedIDs, actionTitle: "Auto Policy")
    defer {
      endRefreshing(pullRequestIDs: trackedIDs)
    }

    let mergeMethod = normalizedPreferences.mergeMethod
    let outcomes = await withTaskGroup(
      of: DashboardReviewsAutoPolicyOutcome.self,
      returning: [DashboardReviewsAutoPolicyOutcome].self
    ) { group in
      for item in items {
        group.addTask {
          await dashboardReviewAutoPolicyOutcome(
            item: item,
            mergeMethod: mergeMethod,
            client: client
          )
        }
      }
      var collected: [DashboardReviewsAutoPolicyOutcome] = []
      for await outcome in group {
        collected.append(outcome)
      }
      let outcomesByPullRequestID = Dictionary(
        uniqueKeysWithValues: collected.map { ($0.item.pullRequestID, $0) }
      )
      return items.compactMap { outcomesByPullRequestID[$0.pullRequestID] }
    }

    cacheReviewPolicyOutcomes(outcomes)
    recordReviewPolicyOutcomes(outcomes, title: "Auto Policy")
    let feedback = dashboardReviewsAutoPolicyFeedback(items: items, outcomes: outcomes)
    switch feedback.severity {
    case .success:
      store.presentSuccessFeedback(feedback.message)
    case .failure:
      store.presentFailureFeedback(feedback.message)
    case .warning, .undoable, .activity:
      store.toast.presentWarning(feedback.message)
    }
    scheduleAffectedRefresh(for: items, using: client)
  }

  func rebaseViaBot(item: ReviewItem, bot: ReviewBot) async {
    guard item.canRebaseViaBot else {
      store.toast.presentWarning(
        DashboardReviewsDisabledReason.rebaseReason(for: item)
          ?? "This pull request cannot be rebased from the dashboard"
      )
      return
    }
    await performMutation(bot.rebaseActionTitle, items: [item]) { client in
      try await client.commentReviews(
        request: ReviewsCommentRequest(
          targets: [item.target],
          body: bot.rebaseCommentBody
        )
      )
    }
  }

  func fixCI(item: ReviewItem) async {
    guard let client = store.apiClient else { return }
    let request = TaskBoardCreateItemRequest(
      title: "Fix CI · \(item.repository)#\(item.number)",
      body: dashboardReviewFixCIBody(for: item, activity: activitySnapshot(for: item)),
      priority: item.requiresAttention ? .high : .medium,
      agentMode: .headless,
      tags: ["reviews", "fix-ci"],
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "\(item.repository)#\(item.number)",
          url: item.url
        )
      ],
      planning: TaskBoardPlanningState(
        summary: "Repair review CI failures and restore mergeability"
      )
    )
    do {
      _ = try await DashboardReviewsTimeoutRacer.race(
        timeoutSeconds: DashboardReviewsTimeoutRacer.defaultMutationTimeoutSeconds
      ) {
        try await client.createTaskBoardItem(request: request)
      }
      selectedRoute = .taskBoard
    } catch {
      store.presentFailureFeedback(error.localizedDescription)
    }
  }

  func performMutation(
    _ title: String,
    items: [ReviewItem],
    onSuccess: @MainActor () -> Void = {},
    operation:
      @Sendable @escaping (any HarnessMonitorClientProtocol) async throws
      -> ReviewsActionResponse
  ) async {
    guard !items.isEmpty else { return }
    guard let client = store.apiClient else { return }
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
      onSuccess()
      scheduleAffectedRefresh(for: items, using: client)
    } catch {
      recordReviewActionFailure(error, title: title, items: items)
      store.presentFailureFeedback(dashboardReviewsErrorMessage(for: error))
    }
  }

  func cacheReviewPolicyOutcomes(_ outcomes: [DashboardReviewsAutoPolicyOutcome]) {
    var previews = routeReviewPolicyPreviewByPullRequestID
    var statuses = routeReviewPolicyStatusByPullRequestID
    for outcome in outcomes {
      if let preview = outcome.preview {
        previews[outcome.item.pullRequestID] = preview
      }
      if let status = outcome.resolvedStatus {
        statuses[outcome.item.pullRequestID] = status
      } else {
        statuses.removeValue(forKey: outcome.item.pullRequestID)
      }
    }
    routeReviewPolicyPreviewByPullRequestID = previews
    routeReviewPolicyStatusByPullRequestID = statuses
  }

}
