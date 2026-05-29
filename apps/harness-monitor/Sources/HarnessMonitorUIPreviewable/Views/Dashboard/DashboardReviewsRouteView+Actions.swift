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
        request: ReviewsApproveRequest(targets: actionableItems.map(\.target))
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
    case .warning, .undoable:
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
      case .warning, .undoable:
        store.toast.presentWarning(feedback.message)
      }
      onSuccess()
      scheduleAffectedRefresh(for: items, using: client)
    } catch {
      recordReviewActionFailure(error, title: title, items: items)
      store.presentFailureFeedback(error.localizedDescription)
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

  func openItem(_ item: ReviewItem) {
    guard let url = URL(string: item.url) else { return }
    openURL(url)
  }

  func copyApprovalLinks(for items: [ReviewItem]) {
    let scopedItems: [ReviewItem]
    if selectedItems.isEmpty, items.count == 1, let repository = items.first?.repository,
      groupMode == .repository
    {
      scopedItems = filteredItems.filter { $0.repository == repository }
    } else {
      scopedItems = items
    }
    let links =
      scopedItems
      .filter { $0.reviewStatus == .reviewRequired }
      .map(\.url)
    guard !links.isEmpty else {
      store.toast.presentWarning("No approval links are needed for the current scope")
      return
    }
    HarnessMonitorClipboard.copy(links.joined(separator: "\n"))
    store.presentSuccessFeedback("Copied \(links.count) approval link(s)")
  }

  func relativeUpdatedLabel(for item: ReviewItem) -> String {
    relativeUpdatedLabels[item.pullRequestID] ?? item.updatedAt
  }

  func toggleRepositoryCollapse(_ repository: String) {
    var collapsed = routeCollapsedRepositories
    collapsed.toggle(repository)
    routeCollapsedRepositories = collapsed
    routeCollapsedRepositoriesStorage = collapsed.encodedString
  }

  func toggleRepositoryPin(_ repository: String) {
    var pinned = routePinnedRepositories
    if pinned.contains(repository) {
      pinned.unpin(repository)
    } else {
      pinned.pin(repository)
    }
    routePinnedRepositories = pinned
    routePinnedRepositoriesStorage = pinned.encodedString
  }

  func reconcileSelection() {
    let liveIDs = Set(routeResponse.items.map(\.pullRequestID))
    routeSelectedIDs = routeSelectedIDs.intersection(liveIDs)
    if routeSelectedIDs.isEmpty, let persisted = persistedPrimarySelectionID.nonEmpty,
      liveIDs.contains(persisted)
    {
      routeSelectedIDs = [persisted]
    }
  }

  func refreshCachedPresentationSelection() {
    let presentation = routeCachedPresentation.applyingSelection(
      selectedIDs: routeSelectedIDs,
      persistedPrimarySelectionID: persistedPrimarySelectionID,
      sortModeRaw: sortModeRaw
    )
    if routeCachedPresentation != presentation {
      routeCachedPresentation = presentation
    }
  }

  @MainActor
  func rebuildPresentation(input: DashboardReviewsListPresentationInput) async {
    routePresentationGeneration &+= 1
    let generation = routePresentationGeneration
    let listPresentation = await routePresentationWorker.computeList(input: input)
    guard !Task.isCancelled, routePresentationGeneration == generation else {
      return
    }
    let presentation = DashboardReviewsPresentation(
      listPresentation: listPresentation,
      selectedIDs: routeSelectedIDs,
      persistedPrimarySelectionID: persistedPrimarySelectionID,
      sortModeRaw: sortModeRaw
    )
    if routeCachedPresentation != presentation {
      routeCachedPresentation = presentation
    }
  }

}

struct DashboardReviewsActionFeedback: Equatable, Sendable {
  let severity: ActionFeedback.Severity
  let message: String
}

struct DashboardReviewsAutoPolicyOutcome: Equatable, Sendable {
  let item: ReviewItem
  let preview: ReviewsPolicyPreviewResponse?
  let run: ReviewsPolicyRunResponse?
  let status: ReviewsPolicyStatusResponse?
  let skippedReason: String?
  let errorMessage: String?

  var resolvedStatus: ReviewsPolicyStatusResponse? {
    dashboardReviewsResolvedPolicyStatus(status, fallbackRun: run)
  }

  var resolvedRun: ReviewsPolicyRunResponse? {
    if let activeRun = resolvedStatus?.activeRun {
      return activeRun
    }
    if let run,
      let matchingRun = resolvedStatus?.recentRuns.first(where: { $0.runID == run.runID })
    {
      return matchingRun
    }
    return dashboardReviewsLatestPolicyRun(resolvedStatus) ?? run
  }

  var finalStatus: ReviewsPolicyRunStatus? {
    resolvedRun?.status
  }

  func activityEntry(title: String) -> DashboardReviewActivityEntry {
    DashboardReviewActivityEntry(
      title: title,
      summary: dashboardReviewsAutoPolicyActivitySummary(self),
      outcome: dashboardReviewsAutoPolicyActivityOutcome(self),
      messages: dashboardReviewsAutoPolicyActivityMessages(self)
    )
  }
}

func dashboardReviewsAutoPolicyFeedback(
  items: [ReviewItem],
  outcomes: [DashboardReviewsAutoPolicyOutcome]
) -> DashboardReviewsActionFeedback {
  guard items.count > 1 else {
    guard let outcome = outcomes.first else {
      return DashboardReviewsActionFeedback(
        severity: .failure,
        message: "Auto policy failed to start."
      )
    }
    return dashboardSingleReviewAutoPolicyFeedback(outcome)
  }

  // Only `.completed` counts as a success. `.waiting`/`.running`/`.pending`
  // are still in flight. Everything else - `.failed`, `.cancelled`,
  // `.unknown(_)`, an error, or a run that never started - is surfaced as
  // needs-attention so the aggregate never renders an all-green success while
  // any run is unfinished.
  let completedCount = outcomes.count { $0.policyAggregationClass == .completed }
  let waitingCount = outcomes.count { $0.policyAggregationClass == .waiting }
  let runningCount = outcomes.count { $0.policyAggregationClass == .running }
  let skippedCount = outcomes.count { $0.policyAggregationClass == .skipped }
  let cancelledCount = outcomes.count { $0.policyAggregationClass == .cancelled }
  let failedCount = outcomes.count { $0.policyAggregationClass == .failed }

  var parts: [String] = []
  if completedCount > 0 {
    parts.append("\(completedCount) completed")
  }
  if waitingCount > 0 {
    parts.append("\(waitingCount) waiting")
  }
  if runningCount > 0 {
    parts.append("\(runningCount) running")
  }
  if skippedCount > 0 {
    parts.append("\(skippedCount) skipped")
  }
  if cancelledCount > 0 {
    parts.append("\(cancelledCount) cancelled")
  }
  if failedCount > 0 {
    parts.append("\(failedCount) failed")
  }
  if parts.isEmpty {
    parts.append("no pull requests started")
  }

  let severity: ActionFeedback.Severity
  if failedCount > 0 || cancelledCount > 0 {
    severity = .failure
  } else if completedCount == outcomes.count {
    severity = .success
  } else {
    severity = .warning
  }

  var message = "Auto policy summary: \(parts.joined(separator: ", "))."
  if let detail = outcomes.lazy.compactMap(dashboardReviewsAutoPolicyDetailMessage(_:)).first,
    severity != .success
  {
    message += " \(detail)"
  }
  return DashboardReviewsActionFeedback(severity: severity, message: message)
}

func dashboardReviewsActionFeedback(
  title _: String,
  items: [ReviewItem],
  response: ReviewsActionResponse
) -> DashboardReviewsActionFeedback {
  if items.count == 1,
    let item = items.first,
    response.results.contains(where: dashboardReviewsIsAutoAction(result:))
  {
    return dashboardSingleReviewAutoActionFeedback(item: item, response: response)
  }
  return dashboardGenericReviewActionFeedback(response: response)
}

private func dashboardSingleReviewAutoActionFeedback(
  item: ReviewItem,
  response: ReviewsActionResponse
) -> DashboardReviewsActionFeedback {
  let pullRequestLabel = "\(item.repository)#\(item.number)"
  let approvalApplied = response.results.contains {
    $0.action == .autoApprove && $0.outcome == .applied
  }
  let mergeApplied = response.results.contains {
    $0.action == .autoMerge && $0.outcome == .applied
  }
  let approvalFailure = response.results.first {
    $0.action == .autoApprove && $0.outcome == .failed
  }
  let mergeFailure = response.results.first {
    $0.action == .autoMerge && $0.outcome == .failed
  }

  if let mergeFailure {
    let failureMessage = dashboardReviewsFailureMessage(
      mergeFailure.message,
      fallback: "GitHub rejected the merge"
    )
    if approvalApplied {
      return DashboardReviewsActionFeedback(
        severity: .failure,
        message: "Approved \(pullRequestLabel), but merge failed: \(failureMessage)"
      )
    }
    return DashboardReviewsActionFeedback(
      severity: .failure,
      message: "Merge failed for \(pullRequestLabel): \(failureMessage)"
    )
  }

  if let approvalFailure {
    let failureMessage = dashboardReviewsFailureMessage(
      approvalFailure.message,
      fallback: "GitHub rejected the approval"
    )
    return DashboardReviewsActionFeedback(
      severity: .failure,
      message: "Approval failed for \(pullRequestLabel): \(failureMessage)"
    )
  }

  if approvalApplied && mergeApplied {
    return DashboardReviewsActionFeedback(
      severity: .success,
      message: "Approved and merged \(pullRequestLabel)"
    )
  }
  if mergeApplied {
    return DashboardReviewsActionFeedback(
      severity: .success,
      message: "Merged \(pullRequestLabel)"
    )
  }
  if approvalApplied {
    let message =
      item.reviewStatus == .reviewRequired
      ? "Approved \(pullRequestLabel). GitHub still requires review before merge."
      : "Approved \(pullRequestLabel)"
    return DashboardReviewsActionFeedback(
      severity: .success,
      message: message
    )
  }
  return dashboardGenericReviewActionFeedback(response: response)
}

private func dashboardGenericReviewActionFeedback(
  response: ReviewsActionResponse
) -> DashboardReviewsActionFeedback {
  let failedMessages = response.results
    .filter { $0.outcome == .failed }
    .compactMap(\.message)
    .map(\.harnessMonitorTrimmedTrailingPeriod)
  if let firstFailure = failedMessages.first {
    return DashboardReviewsActionFeedback(
      severity: .failure,
      message: "\(response.summary.harnessMonitorTrimmedTrailingPeriod). \(firstFailure)"
    )
  }
  if response.results.contains(where: { $0.outcome == .failed }) {
    return DashboardReviewsActionFeedback(
      severity: .failure,
      message: response.summary
    )
  }
  return DashboardReviewsActionFeedback(
    severity: .success,
    message: response.summary
  )
}

private func dashboardReviewsFailureMessage(
  _ message: String?,
  fallback: String
) -> String {
  guard let message, !message.isEmpty else {
    return fallback
  }
  return message.harnessMonitorTrimmedTrailingPeriod
}

private func dashboardReviewsIsAutoAction(result: ReviewActionResult) -> Bool {
  result.action == .autoApprove || result.action == .autoMerge
}

private func dashboardReviewAutoPolicyOutcome(
  item: ReviewItem,
  mergeMethod: TaskBoardGitHubMergeMethod,
  client: any HarnessMonitorClientProtocol
) async -> DashboardReviewsAutoPolicyOutcome {
  let preview: ReviewsPolicyPreviewResponse
  do {
    preview = try await DashboardReviewsTimeoutRacer.race(
      timeoutSeconds: DashboardReviewsTimeoutRacer.defaultMutationTimeoutSeconds
    ) {
      try await client.previewReviewsPolicy(
        ReviewsPolicyPreviewRequest(
          target: item.target,
          method: mergeMethod
        )
      )
    }
  } catch {
    return DashboardReviewsAutoPolicyOutcome(
      item: item,
      preview: nil,
      run: nil,
      status: nil,
      skippedReason: nil,
      errorMessage: error.localizedDescription
    )
  }

  guard preview.eligible, !preview.steps.isEmpty else {
    return DashboardReviewsAutoPolicyOutcome(
      item: item,
      preview: preview,
      run: nil,
      status: nil,
      skippedReason: preview.reason ?? "No policy actions are currently applicable.",
      errorMessage: nil
    )
  }

  let run: ReviewsPolicyRunResponse
  do {
    run = try await DashboardReviewsTimeoutRacer.race(
      timeoutSeconds: DashboardReviewsTimeoutRacer.defaultMutationTimeoutSeconds
    ) {
      try await client.startReviewsPolicyRun(
        ReviewsPolicyRunStartRequest(
          target: item.target,
          method: mergeMethod,
          trigger: .manual
        )
      )
    }
  } catch {
    return DashboardReviewsAutoPolicyOutcome(
      item: item,
      preview: preview,
      run: nil,
      status: nil,
      skippedReason: nil,
      errorMessage: error.localizedDescription
    )
  }

  do {
    let status = try await DashboardReviewsTimeoutRacer.race(
      timeoutSeconds: DashboardReviewsTimeoutRacer.defaultMutationTimeoutSeconds
    ) {
      try await client.reviewsPolicyStatus(
        ReviewsPolicyStatusRequest(
          subject: run.subject,
          workflowID: run.workflowID
        )
      )
    }
    return DashboardReviewsAutoPolicyOutcome(
      item: item,
      preview: preview,
      run: run,
      status: status,
      skippedReason: nil,
      errorMessage: nil
    )
  } catch {
    HarnessMonitorLogger.api.warning(
      "Reviews policy status refresh failed for \(item.repository)#\(item.number): \(String(reflecting: error), privacy: .public)"
    )
    return DashboardReviewsAutoPolicyOutcome(
      item: item,
      preview: preview,
      run: run,
      status: nil,
      skippedReason: nil,
      errorMessage: nil
    )
  }
}

private func dashboardReviewsResolvedPolicyStatus(
  _ status: ReviewsPolicyStatusResponse?,
  fallbackRun: ReviewsPolicyRunResponse?
) -> ReviewsPolicyStatusResponse? {
  if let status,
    status.activeRun != nil || !status.recentRuns.isEmpty
  {
    return status
  }
  guard let fallbackRun else { return status }
  return ReviewsPolicyStatusResponse(
    activeRun: fallbackRun.status.isActive ? fallbackRun : nil,
    recentRuns: [fallbackRun]
  )
}

private func dashboardSingleReviewAutoPolicyFeedback(
  _ outcome: DashboardReviewsAutoPolicyOutcome
) -> DashboardReviewsActionFeedback {
  let pullRequestLabel = "\(outcome.item.repository)#\(outcome.item.number)"
  if let errorMessage = outcome.errorMessage {
    return DashboardReviewsActionFeedback(
      severity: .failure,
      message: "Auto policy failed for \(pullRequestLabel): "
        + dashboardReviewsFailureMessage(errorMessage, fallback: "Unknown error")
    )
  }
  if let skippedReason = outcome.skippedReason {
    return DashboardReviewsActionFeedback(
      severity: .warning,
      message: "Auto policy did not start for \(pullRequestLabel): "
        + dashboardReviewsFailureMessage(skippedReason, fallback: "Not eligible")
    )
  }

  switch outcome.finalStatus {
  case .completed:
    if let effects = dashboardReviewsJoinedPolicyEffects(
      dashboardReviewsAutoPolicyEffects(outcome.resolvedRun?.steps ?? [])
    ) {
      return DashboardReviewsActionFeedback(
        severity: .success,
        message: "Auto policy completed for \(pullRequestLabel): \(effects)."
      )
    }
    return DashboardReviewsActionFeedback(
      severity: .success,
      message: "Auto policy completed for \(pullRequestLabel)."
    )
  case .waiting:
    let waitingLabel =
      dashboardReviewsPolicyWaitLabel(outcome.resolvedRun?.waitingOn)
      ?? "the configured policy condition"
    if let effects = dashboardReviewsJoinedPolicyEffects(
      dashboardReviewsAutoPolicyEffects(outcome.resolvedRun?.steps ?? [])
    ) {
      return DashboardReviewsActionFeedback(
        severity: .warning,
        message: "Auto policy started for \(pullRequestLabel): \(effects); waiting for \(waitingLabel)."
      )
    }
    return DashboardReviewsActionFeedback(
      severity: .warning,
      message: "Auto policy started for \(pullRequestLabel) and is waiting for \(waitingLabel)."
    )
  case .pending, .running:
    return DashboardReviewsActionFeedback(
      severity: .warning,
      message: "Auto policy started for \(pullRequestLabel)."
    )
  case .cancelled:
    return DashboardReviewsActionFeedback(
      severity: .warning,
      message: "Auto policy was cancelled for \(pullRequestLabel)."
    )
  case .failed:
    return DashboardReviewsActionFeedback(
      severity: .failure,
      message: "Auto policy failed for \(pullRequestLabel): "
        + dashboardReviewsFailureMessage(
          outcome.resolvedRun?.errorMessage,
          fallback: "Unknown error"
        )
    )
  case .unknown(let rawValue):
    return DashboardReviewsActionFeedback(
      severity: .warning,
      message: "Auto policy entered \(rawValue) for \(pullRequestLabel)."
    )
  case nil:
    return DashboardReviewsActionFeedback(
      severity: .failure,
      message: "Auto policy failed to start for \(pullRequestLabel)."
    )
  }
}

private func dashboardReviewsAutoPolicyDetailMessage(
  _ outcome: DashboardReviewsAutoPolicyOutcome
) -> String? {
  let pullRequestLabel = "\(outcome.item.repository)#\(outcome.item.number)"
  if let errorMessage = outcome.errorMessage {
    return "\(pullRequestLabel): "
      + dashboardReviewsFailureMessage(errorMessage, fallback: "Unknown error")
  }
  if let skippedReason = outcome.skippedReason {
    return "\(pullRequestLabel): "
      + dashboardReviewsFailureMessage(skippedReason, fallback: "Not eligible")
  }
  switch outcome.finalStatus {
  case .failed:
    return "\(pullRequestLabel): "
      + dashboardReviewsFailureMessage(
        outcome.resolvedRun?.errorMessage,
        fallback: "Unknown error"
      )
  case .cancelled:
    return "\(pullRequestLabel) was cancelled."
  case .unknown(let rawValue):
    return "\(pullRequestLabel) entered \(rawValue)."
  case nil:
    return "\(pullRequestLabel) failed to start."
  default:
    return nil
  }
}

private func dashboardReviewsAutoPolicyActivityOutcome(
  _ outcome: DashboardReviewsAutoPolicyOutcome
) -> DashboardReviewActivityEntry.Outcome {
  if outcome.errorMessage != nil || outcome.finalStatus == .failed || outcome.finalStatus == nil {
    return .failure
  }
  if outcome.finalStatus == .completed {
    return .success
  }
  return .warning
}

private func dashboardReviewsAutoPolicyActivitySummary(
  _ outcome: DashboardReviewsAutoPolicyOutcome
) -> String {
  if let errorMessage = outcome.errorMessage {
    return "Auto policy failed: "
      + dashboardReviewsFailureMessage(errorMessage, fallback: "Unknown error")
  }
  if let skippedReason = outcome.skippedReason {
    return "Auto policy did not start: "
      + dashboardReviewsFailureMessage(skippedReason, fallback: "Not eligible")
  }
  switch outcome.finalStatus {
  case .completed:
    if let effects = dashboardReviewsJoinedPolicyEffects(
      dashboardReviewsAutoPolicyEffects(outcome.resolvedRun?.steps ?? [])
    ) {
      return "Auto policy completed: \(effects)."
    }
    return "Auto policy completed."
  case .waiting:
    if let waitingLabel = dashboardReviewsPolicyWaitLabel(outcome.resolvedRun?.waitingOn) {
      return "Auto policy is waiting for \(waitingLabel)."
    }
    return "Auto policy is waiting."
  case .pending, .running:
    return "Auto policy started."
  case .cancelled:
    return "Auto policy was cancelled."
  case .failed:
    return "Auto policy failed: "
      + dashboardReviewsFailureMessage(
        outcome.resolvedRun?.errorMessage,
        fallback: "Unknown error"
      )
  case .unknown(let rawValue):
    return "Auto policy entered \(rawValue)."
  case nil:
    return "Auto policy failed to start."
  }
}

private func dashboardReviewsAutoPolicyActivityMessages(
  _ outcome: DashboardReviewsAutoPolicyOutcome
) -> [String] {
  var messages: [String] = []
  if let effects = dashboardReviewsJoinedPolicyEffects(
    dashboardReviewsAutoPolicyEffects(outcome.resolvedRun?.steps ?? [])
  ) {
    messages.append("Completed: \(dashboardReviewsSentenceCase(effects)).")
  }
  if let waitingLabel = dashboardReviewsPolicyWaitLabel(outcome.resolvedRun?.waitingOn) {
    messages.append("Waiting on: \(waitingLabel)")
  }
  if let run = outcome.resolvedRun {
    messages.append("Workflow: \(run.workflowID)")
  }
  return messages
}

private func dashboardReviewsAutoPolicyEffects(
  _ steps: [ReviewsPolicyRunStep]
) -> [String] {
  var effects: [String] = []
  for step in steps where step.stepType == .action {
    switch step.actionKey {
    case "reviews.approve":
      effects.append("approved")
    case "reviews.merge":
      effects.append("merged")
    case let actionKey? where !actionKey.isEmpty:
      effects.append(
        actionKey
          .replacingOccurrences(of: ".", with: " ")
          .replacingOccurrences(of: "_", with: " ")
      )
    default:
      break
    }
  }
  return dashboardReviewsOrderedUniqueEffects(effects)
}

private func dashboardReviewsOrderedUniqueEffects(
  _ effects: [String]
) -> [String] {
  var ordered: [String] = []
  var seen = Set<String>()
  for effect in effects where seen.insert(effect).inserted {
    ordered.append(effect)
  }
  return ordered
}

private func dashboardReviewsJoinedPolicyEffects(
  _ effects: [String]
) -> String? {
  guard let first = effects.first else { return nil }
  guard effects.count > 1 else { return first }
  if effects.count == 2, let last = effects.last {
    return "\(first) and \(last)"
  }
  return effects.dropLast().joined(separator: ", ")
    + ", and "
    + (effects.last ?? "")
}

private func dashboardReviewsSentenceCase(_ value: String) -> String {
  guard let first = value.first else { return value }
  return first.uppercased() + value.dropFirst()
}
