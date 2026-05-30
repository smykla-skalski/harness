import HarnessMonitorKit
import SwiftUI

extension DashboardReviewsRouteView {
  func loadReviewCapabilitiesIfNeeded(
    client: any HarnessMonitorReviewsClientProtocol
  ) async {
    guard routeReviewCapabilities.schemaVersion == 0 else { return }
    do {
      routeReviewCapabilities = try await DashboardReviewsTimeoutRacer.race(
        timeoutSeconds: DashboardReviewsTimeoutRacer.defaultMutationTimeoutSeconds
      ) {
        try await client.reviewsCapabilities()
      }
    } catch {
      HarnessMonitorLogger.api.warning(
        "Reviews capabilities request failed: \(String(reflecting: error), privacy: .public)"
      )
      routeReviewCapabilities = .fallback
    }
  }

  func requestApproveOrConfirm(items: [ReviewItem]) {
    trackInFlight(Task { await requestReviewAction(.approve, items: items) })
  }

  func requestMerge(items: [ReviewItem]) {
    requestMergeOrConfirm(items: items)
  }

  func requestMergeOrConfirm(items: [ReviewItem]) {
    trackInFlight(Task { await requestReviewAction(.merge, items: items) })
  }

  func requestAuto(items: [ReviewItem]) {
    trackInFlight(Task { await requestReviewAction(.auto, items: items) })
  }

  func confirmReviewAction(_ confirmation: DashboardReviewActionConfirmation) {
    let items = currentItems(for: confirmation.pullRequestIDs)
    guard !items.isEmpty else { return }
    if confirmation.action == .approve, confirmation.approvalSubmission.isQueued {
      enqueuePastedReviewApproval(
        items: items,
        dryRun: confirmation.approvalSubmission.isDryRun
      )
      return
    }
    trackInFlight(Task { await performReviewAction(confirmation.action, items: items) })
  }

  func requestReviewAction(
    _ action: DashboardReviewAttentionActionKind,
    items: [ReviewItem]
  ) async {
    guard !items.isEmpty else { return }
    if action == .auto {
      let preview = await reviewAutoPolicyPreview(items: items)
      guard preview.actionableCount > 0 else {
        store.toast.presentWarning(
          preview.firstReason ?? "No selected review can start the auto policy"
        )
        return
      }
      if let confirmation = dashboardReviewActionConfirmation(
        for: action,
        items: items,
        preview: preview,
        mergeMethod: normalizedPreferences.mergeMethod
      ) {
        routePendingActionConfirmation = confirmation
        return
      }
      await performReviewAction(action, items: items)
      return
    }
    let preview = await reviewActionPreview(action, items: items)
    guard preview.actionableCount > 0 else {
      store.toast.presentWarning(
        preview.targets.first?.reason ?? "No selected review can run this action"
      )
      return
    }
    if let confirmation = dashboardReviewActionConfirmation(
      for: action,
      items: items,
      preview: preview,
      mergeMethod: normalizedPreferences.mergeMethod
    ) {
      routePendingActionConfirmation = confirmation
      return
    }
    await performReviewAction(action, items: items)
  }

  func performReviewAction(
    _ action: DashboardReviewAttentionActionKind,
    items: [ReviewItem]
  ) async {
    switch action {
    case .approve:
      await approve(items: items)
    case .merge:
      await merge(items: items)
    case .auto:
      await auto(items: items)
    }
  }

  func reviewAutoPolicyPreview(
    items: [ReviewItem]
  ) async -> DashboardReviewsAutoPolicyPreview {
    guard let client = store.apiClient else {
      let preview = localReviewAutoPolicyPreview(items: items)
      cacheReviewPolicyPreviews(preview.targets)
      return preview
    }
    let mergeMethod = normalizedPreferences.mergeMethod
    let targets = await withTaskGroup(
      of: DashboardReviewsAutoPolicyPreviewTarget.self,
      returning: [DashboardReviewsAutoPolicyPreviewTarget].self
    ) { group in
      for item in items {
        group.addTask {
          await remoteReviewAutoPolicyPreviewTarget(
            item: item,
            mergeMethod: mergeMethod,
            client: client
          )
        }
      }
      var collected: [DashboardReviewsAutoPolicyPreviewTarget] = []
      for await target in group {
        collected.append(target)
      }
      let targetsByPullRequestID = Dictionary(
        uniqueKeysWithValues: collected.map { ($0.pullRequestID, $0) }
      )
      return items.compactMap { targetsByPullRequestID[$0.pullRequestID] }
    }
    cacheReviewPolicyPreviews(targets)
    return DashboardReviewsAutoPolicyPreview(targets: targets)
  }

  func reviewActionPreview(
    _ action: DashboardReviewAttentionActionKind,
    items: [ReviewItem]
  ) async -> ReviewsActionPreviewResponse {
    let request = ReviewsActionPreviewRequest(
      action: action.previewKind,
      targets: items.map(\.target),
      method: normalizedPreferences.mergeMethod
    )
    guard let client = store.apiClient else {
      return localReviewActionPreview(action.previewKind, items: items)
    }
    do {
      let preview = try await DashboardReviewsTimeoutRacer.race(
        timeoutSeconds: DashboardReviewsTimeoutRacer.defaultMutationTimeoutSeconds
      ) {
        try await client.previewReviewAction(request: request)
      }
      routeReviewCapabilities = preview.capabilities
      return preview
    } catch {
      HarnessMonitorLogger.api.warning(
        "Review action preview failed: \(String(reflecting: error), privacy: .public)"
      )
      return localReviewActionPreview(action.previewKind, items: items)
    }
  }

  func cacheReviewPolicyPreviews(_ targets: [DashboardReviewsAutoPolicyPreviewTarget]) {
    var previews = routeReviewPolicyPreviewByPullRequestID
    for target in targets {
      previews[target.pullRequestID] = target.preview
    }
    routeReviewPolicyPreviewByPullRequestID = previews
  }

  func currentItems(for pullRequestIDs: [String]) -> [ReviewItem] {
    let itemsByID = Dictionary(
      uniqueKeysWithValues: routeResponse.items.map { ($0.pullRequestID, $0) }
    )
    return pullRequestIDs.compactMap { itemsByID[$0] }
  }
}

func localReviewActionPreview(
  _ action: ReviewActionPreviewKind,
  items: [ReviewItem]
) -> ReviewsActionPreviewResponse {
  let targets = items.map { item in
    let reason = localReviewActionBlocker(action, item: item)
    return ReviewActionPreviewTarget(
      pullRequestID: item.pullRequestID,
      repository: item.repository,
      number: item.number,
      eligible: reason == nil,
      reason: reason,
      warnings: localReviewActionWarnings(action, item: item)
    )
  }
  let actionableCount = targets.count(where: \.eligible)
  return ReviewsActionPreviewResponse(
    action: action,
    totalCount: items.count,
    actionableCount: actionableCount,
    skippedCount: items.count - actionableCount,
    warnings: localReviewActionWarnings(action, items: items),
    targets: targets
  )
}

func localReviewAutoPolicyPreview(
  items: [ReviewItem]
) -> DashboardReviewsAutoPolicyPreview {
  DashboardReviewsAutoPolicyPreview(
    targets: items.map(localReviewAutoPolicyPreviewTarget(item:))
  )
}

func localReviewAutoPolicyPreviewTarget(
  item: ReviewItem
) -> DashboardReviewsAutoPolicyPreviewTarget {
  let reason = localReviewActionBlocker(.auto, item: item)
  var steps: [ReviewsPolicyPreviewStep] = []
  if reason == nil {
    if item.reviewStatus != .approved {
      steps.append(
        ReviewsPolicyPreviewStep(stepType: .action, actionKey: "reviews.approve")
      )
    }
    if item.checkStatus != .success {
      steps.append(
        ReviewsPolicyPreviewStep(
          stepType: .wait,
          waitingOn: ReviewsPolicyWait(eventKey: "reviews.checks_passed")
        )
      )
    }
    if item.mergeable == .mergeable || item.viewerCanMergeAsAdmin {
      steps.append(
        ReviewsPolicyPreviewStep(stepType: .action, actionKey: "reviews.merge")
      )
    }
  }
  let preview = ReviewsPolicyPreviewResponse(
    eligible: reason == nil && !steps.isEmpty,
    reason: steps.isEmpty ? (reason ?? "No policy actions are currently applicable.") : reason,
    steps: steps,
    warnings: localReviewActionWarnings(.auto, item: item)
  )
  return DashboardReviewsAutoPolicyPreviewTarget(item: item, preview: preview)
}

private func remoteReviewAutoPolicyPreviewTarget(
  item: ReviewItem,
  mergeMethod: TaskBoardGitHubMergeMethod,
  client: any HarnessMonitorClientProtocol
) async -> DashboardReviewsAutoPolicyPreviewTarget {
  do {
    let preview = try await DashboardReviewsTimeoutRacer.race(
      timeoutSeconds: DashboardReviewsTimeoutRacer.defaultMutationTimeoutSeconds
    ) {
      try await client.previewReviewsPolicy(
        ReviewsPolicyPreviewRequest(
          target: item.target,
          method: mergeMethod
        )
      )
    }
    return DashboardReviewsAutoPolicyPreviewTarget(item: item, preview: preview)
  } catch {
    HarnessMonitorLogger.api.warning(
      """
      Reviews policy preview failed for \(item.repository)#\(item.number): \
      \(String(reflecting: error), privacy: .public)
      """
    )
    let preview = ReviewsPolicyPreviewResponse(
      eligible: false,
      reason:
        "Auto policy preview failed: \(error.localizedDescription.harnessMonitorTrimmedTrailingPeriod)."
    )
    return DashboardReviewsAutoPolicyPreviewTarget(item: item, preview: preview)
  }
}

private func localReviewActionBlocker(
  _ action: ReviewActionPreviewKind,
  item: ReviewItem
) -> String? {
  switch action {
  case .approve:
    return item.canAttemptManualApproval
      ? nil
      : DashboardReviewsDisabledReason.approveReason(for: [item])
  case .merge:
    return item.canAttemptManualMerge
      ? nil
      : DashboardReviewsDisabledReason.mergeReason(for: [item])
  case .rerunChecks:
    return item.canAttemptRerunChecks
      ? nil
      : DashboardReviewsDisabledReason.rerunReason(for: [item])
  case .addLabel:
    return item.canAddReviewLabel
      ? nil
      : DashboardReviewsDisabledReason.labelReason(for: [item])
  case .auto:
    return item.canRunAutoMode
      ? nil
      : DashboardReviewsDisabledReason.autoReason(for: [item])
  case .unknown:
    return "Unknown review action"
  }
}

private func localReviewActionWarnings(
  _ action: ReviewActionPreviewKind,
  items: [ReviewItem]
) -> [String] {
  DashboardReviewBatchEligibility.preview(
    kind: action.batchActionKind,
    items: items
  )
  .skippedReasons
  .prefix(3)
  .map { "\($0.count) \($0.reason)" }
}

private func localReviewActionWarnings(
  _ action: ReviewActionPreviewKind,
  item: ReviewItem
) -> [String] {
  var warnings: [String] = []
  if (action == .approve || action == .merge) && item.checkStatus == .failure {
    warnings.append("Checks are failing")
  }
  if item.policyBlocked {
    warnings.append("Review policy is blocking this pull request")
  }
  if item.reviewStatus == .changesRequested {
    warnings.append("A reviewer requested changes")
  }
  return warnings
}

extension ReviewActionPreviewKind {
  fileprivate var batchActionKind: DashboardReviewBatchActionKind {
    switch self {
    case .approve: .approve
    case .merge: .merge
    case .rerunChecks: .rerunChecks
    case .addLabel: .label
    case .auto, .unknown: .auto
    }
  }
}
