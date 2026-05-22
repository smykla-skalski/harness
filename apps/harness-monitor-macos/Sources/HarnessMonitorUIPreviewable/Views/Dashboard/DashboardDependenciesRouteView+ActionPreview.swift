import HarnessMonitorKit
import SwiftUI

extension DashboardDependenciesRouteView {
  func loadDependencyCapabilitiesIfNeeded(
    client: any HarnessMonitorDependenciesClientProtocol
  ) async {
    guard routeDependencyCapabilities.schemaVersion == 0 else { return }
    do {
      routeDependencyCapabilities = try await DashboardDependenciesTimeoutRacer.race(
        timeoutSeconds: DashboardDependenciesTimeoutRacer.defaultMutationTimeoutSeconds
      ) {
        try await client.dependencyUpdatesCapabilities()
      }
    } catch {
      HarnessMonitorLogger.api.warning(
        "Dependency capabilities request failed: \(String(reflecting: error), privacy: .public)"
      )
      routeDependencyCapabilities = .fallback
    }
  }

  func requestApproveOrConfirm(items: [DependencyUpdateItem]) {
    trackInFlight(Task { await requestDependencyAction(.approve, items: items) })
  }

  func requestMerge(items: [DependencyUpdateItem]) {
    requestMergeOrConfirm(items: items)
  }

  func requestMergeOrConfirm(items: [DependencyUpdateItem]) {
    trackInFlight(Task { await requestDependencyAction(.merge, items: items) })
  }

  func requestAuto(items: [DependencyUpdateItem]) {
    trackInFlight(Task { await requestDependencyAction(.auto, items: items) })
  }

  func confirmDependencyAction(_ confirmation: DashboardDependencyActionConfirmation) {
    let items = currentItems(for: confirmation.pullRequestIDs)
    guard !items.isEmpty else { return }
    trackInFlight(Task { await performDependencyAction(confirmation.action, items: items) })
  }

  func requestDependencyAction(
    _ action: DashboardDependencyAttentionActionKind,
    items: [DependencyUpdateItem]
  ) async {
    guard !items.isEmpty else { return }
    let preview = await dependencyActionPreview(action, items: items)
    guard preview.actionableCount > 0 else {
      store.toast.presentWarning(
        preview.targets.first?.reason ?? "No selected dependency update can run this action"
      )
      return
    }
    if let confirmation = dashboardDependencyActionConfirmation(
      for: action,
      items: items,
      preview: preview,
      mergeMethod: normalizedPreferences.mergeMethod
    ) {
      routePendingActionConfirmation = confirmation
      return
    }
    await performDependencyAction(action, items: items)
  }

  func performDependencyAction(
    _ action: DashboardDependencyAttentionActionKind,
    items: [DependencyUpdateItem]
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

  func dependencyActionPreview(
    _ action: DashboardDependencyAttentionActionKind,
    items: [DependencyUpdateItem]
  ) async -> DependencyUpdatesActionPreviewResponse {
    let request = DependencyUpdatesActionPreviewRequest(
      action: action.previewKind,
      targets: items.map(\.target),
      method: normalizedPreferences.mergeMethod
    )
    guard let client = store.apiClient else {
      return localDependencyActionPreview(action.previewKind, items: items)
    }
    do {
      let preview = try await DashboardDependenciesTimeoutRacer.race(
        timeoutSeconds: DashboardDependenciesTimeoutRacer.defaultMutationTimeoutSeconds
      ) {
        try await client.previewDependencyUpdateAction(request: request)
      }
      routeDependencyCapabilities = preview.capabilities
      return preview
    } catch {
      HarnessMonitorLogger.api.warning(
        "Dependency action preview failed: \(String(reflecting: error), privacy: .public)"
      )
      return localDependencyActionPreview(action.previewKind, items: items)
    }
  }

  func currentItems(for pullRequestIDs: [String]) -> [DependencyUpdateItem] {
    let itemsByID = Dictionary(
      uniqueKeysWithValues: routeResponse.items.map { ($0.pullRequestID, $0) }
    )
    return pullRequestIDs.compactMap { itemsByID[$0] }
  }
}

func localDependencyActionPreview(
  _ action: DependencyUpdateActionPreviewKind,
  items: [DependencyUpdateItem]
) -> DependencyUpdatesActionPreviewResponse {
  let targets = items.map { item in
    let reason = localDependencyActionBlocker(action, item: item)
    return DependencyUpdateActionPreviewTarget(
      pullRequestID: item.pullRequestID,
      repository: item.repository,
      number: item.number,
      eligible: reason == nil,
      reason: reason,
      warnings: localDependencyActionWarnings(action, item: item)
    )
  }
  let actionableCount = targets.count(where: \.eligible)
  return DependencyUpdatesActionPreviewResponse(
    action: action,
    totalCount: items.count,
    actionableCount: actionableCount,
    skippedCount: items.count - actionableCount,
    warnings: localDependencyActionWarnings(action, items: items),
    targets: targets
  )
}

private func localDependencyActionBlocker(
  _ action: DependencyUpdateActionPreviewKind,
  item: DependencyUpdateItem
) -> String? {
  switch action {
  case .approve:
    return item.canAttemptManualApproval
      ? nil
      : DashboardDependenciesDisabledReason.approveReason(for: [item])
  case .merge:
    return item.canAttemptManualMerge
      ? nil
      : DashboardDependenciesDisabledReason.mergeReason(for: [item])
  case .rerunChecks:
    return item.canAttemptRerunChecks
      ? nil
      : DashboardDependenciesDisabledReason.rerunReason(for: [item])
  case .addLabel:
    return item.canAddDependencyLabel
      ? nil
      : DashboardDependenciesDisabledReason.labelReason(for: [item])
  case .auto:
    return item.canRunAutoMode
      ? nil
      : DashboardDependenciesDisabledReason.autoReason(for: [item])
  case .unknown:
    return "Unknown dependency action"
  }
}

private func localDependencyActionWarnings(
  _ action: DependencyUpdateActionPreviewKind,
  items: [DependencyUpdateItem]
) -> [String] {
  DashboardDependencyBatchEligibility.preview(
    kind: action.batchActionKind,
    items: items
  )
  .skippedReasons
  .prefix(3)
  .map { "\($0.count) \($0.reason)" }
}

private func localDependencyActionWarnings(
  _ action: DependencyUpdateActionPreviewKind,
  item: DependencyUpdateItem
) -> [String] {
  var warnings: [String] = []
  if (action == .approve || action == .merge) && item.checkStatus == .failure {
    warnings.append("Checks are failing")
  }
  if item.policyBlocked {
    warnings.append("Dependency policy is blocking this pull request")
  }
  if item.reviewStatus == .changesRequested {
    warnings.append("A reviewer requested changes")
  }
  return warnings
}

extension DependencyUpdateActionPreviewKind {
  fileprivate var batchActionKind: DashboardDependencyBatchActionKind {
    switch self {
    case .approve: .approve
    case .merge: .merge
    case .rerunChecks: .rerunChecks
    case .addLabel: .label
    case .auto, .unknown: .auto
    }
  }
}
