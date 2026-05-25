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
    let actionableItems = items.filter(\.canRunAutoMode)
    await performMutation("Auto-merging", items: actionableItems) { client in
      try await client.autoReviews(
        request: ReviewsAutoRequest(
          targets: actionableItems.map(\.target),
          method: normalizedPreferences.mergeMethod
        )
      )
    }
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
      store.presentSuccessFeedback(response.summary)
      onSuccess()
      scheduleAffectedRefresh(for: items, using: client)
    } catch {
      recordReviewActionFailure(error, title: title, items: items)
      store.presentFailureFeedback(error.localizedDescription)
    }
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
