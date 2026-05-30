import HarnessMonitorKit
import SwiftUI

enum DashboardReviewAttentionActionKind {
  case approve
  case merge
  case auto

  var previewKind: ReviewActionPreviewKind {
    switch self {
    case .approve: .approve
    case .merge: .merge
    case .auto: .auto
    }
  }
}

enum DashboardReviewAttentionBadgeKind: String, Identifiable {
  case requiredChecks
  case failingChecks
  case changesRequested
  case policyBlocked
  case mergeConflicts
  case slaBreached

  var id: String { rawValue }

  var label: String {
    switch self {
    case .requiredChecks:
      "Required checks"
    case .changesRequested:
      "Changes requested"
    case .mergeConflicts:
      "Conflicts"
    case .failingChecks:
      "Checks failing"
    case .policyBlocked:
      "Policy blocked"
    case .slaBreached:
      "SLA Breached"
    }
  }

  var systemImage: String? {
    switch self {
    case .requiredChecks:
      "exclamationmark.triangle"
    case .failingChecks:
      "xmark.circle"
    case .changesRequested:
      "arrow.uturn.backward"
    case .policyBlocked:
      "hourglass"
    case .mergeConflicts:
      "arrow.triangle.merge"
    case .slaBreached:
      "clock.badge.exclamationmark"
    }
  }

  var tint: Color {
    switch self {
    case .requiredChecks, .changesRequested, .mergeConflicts:
      HarnessMonitorTheme.danger
    case .failingChecks, .policyBlocked, .slaBreached:
      HarnessMonitorTheme.caution
    }
  }
}

struct DashboardReviewAttentionBadges: Equatable {
  let hasRequiredChecks: Bool
  let hasFailingChecks: Bool
  let hasChangesRequested: Bool
  let hasPolicyBlocked: Bool
  let hasMergeConflicts: Bool
  let hasSlaBreach: Bool
  init(item: ReviewItem, slaThresholdHours: Int? = nil, currentDate: Date = Date()) {
    hasRequiredChecks = item.hasRequiredFailedChecks
    hasFailingChecks = !item.hasRequiredFailedChecks && item.checkStatus == .failure
    hasChangesRequested = item.reviewStatus == .changesRequested
    hasPolicyBlocked = item.policyBlocked
    hasMergeConflicts = item.mergeable == .conflicting

    if let threshold = slaThresholdHours, threshold > 0 {
      let formatter = ISO8601DateFormatter()
      if let createdDate = formatter.date(from: item.createdAt) {
        let ageInHours = currentDate.timeIntervalSince(createdDate) / 3600
        hasSlaBreach = ageInHours > Double(threshold)
      } else {
        hasSlaBreach = false
      }
    } else {
      hasSlaBreach = false
    }
  }
  var isEmpty: Bool {
    !hasRequiredChecks
      && !hasFailingChecks
      && !hasChangesRequested
      && !hasPolicyBlocked
      && !hasMergeConflicts
      && !hasSlaBreach
  }
  var kinds: [DashboardReviewAttentionBadgeKind] {
    [
      hasRequiredChecks ? .requiredChecks : nil,
      hasChangesRequested ? .changesRequested : nil,
      hasMergeConflicts ? .mergeConflicts : nil,
      hasFailingChecks ? .failingChecks : nil,
      hasPolicyBlocked ? .policyBlocked : nil,
      hasSlaBreach ? .slaBreached : nil,
    ].compactMap(\.self)
  }
}

struct DashboardReviewActionConfirmation {
  let action: DashboardReviewAttentionActionKind
  let pullRequestIDs: [String]
  let title: String
  let message: String
  let confirmButtonTitle: String
  let confirmRole: ButtonRole?
  var approvalSubmission: DashboardReviewApprovalSubmission = .inline
}

enum DashboardReviewApprovalSubmission: Equatable, Sendable {
  case inline
  case queued(dryRun: Bool)

  var isQueued: Bool {
    if case .queued = self {
      return true
    }
    return false
  }

  var isDryRun: Bool {
    if case .queued(let dryRun) = self {
      return dryRun
    }
    return false
  }
}

struct DashboardReviewsAutoPolicyPreviewTarget: Equatable, Sendable {
  let pullRequestID: String
  let repository: String
  let number: UInt64
  let preview: ReviewsPolicyPreviewResponse

  init(item: ReviewItem, preview: ReviewsPolicyPreviewResponse) {
    pullRequestID = item.pullRequestID
    repository = item.repository
    number = item.number
    self.preview = preview
  }

  var eligible: Bool { preview.eligible }
  var reason: String? { preview.reason }
  var warnings: [String] { preview.warnings }
  var steps: [ReviewsPolicyPreviewStep] { preview.steps }
}

struct DashboardReviewsAutoPolicyPreview: Equatable, Sendable {
  let targets: [DashboardReviewsAutoPolicyPreviewTarget]
  let warnings: [String]

  init(targets: [DashboardReviewsAutoPolicyPreviewTarget]) {
    self.targets = targets
    warnings = dashboardReviewsAutoPolicyWarnings(targets)
  }

  var totalCount: Int { targets.count }
  var actionableCount: Int { targets.count(where: \.eligible) }
  var skippedCount: Int { totalCount - actionableCount }
  var firstReason: String? { targets.first(where: { !$0.eligible })?.reason }

  var containsWaits: Bool {
    targets.contains { target in
      target.steps.contains { $0.stepType == .wait }
    }
  }

  var requiresConfirmation: Bool {
    totalCount > 1
      || skippedCount > 0
      || !warnings.isEmpty
      || containsWaits
      || targets.contains { $0.steps.count > 1 }
  }
}

func dashboardReviewMergeActionTitle(for items: [ReviewItem]) -> String {
  items.contains(where: \.requiresAdminMergeForRequiredFailures) ? "Merge as Admin" : "Merge"
}

func dashboardReviewAttentionBadgeKinds(
  for item: ReviewItem,
  slaThresholdHours: Int? = nil
) -> [DashboardReviewAttentionBadgeKind] {
  DashboardReviewAttentionBadges(item: item, slaThresholdHours: slaThresholdHours).kinds
}

func dashboardReviewActionConfirmation(
  for action: DashboardReviewAttentionActionKind,
  items: [ReviewItem]
) -> DashboardReviewActionConfirmation? {
  if action == .auto {
    return dashboardReviewActionConfirmation(
      for: action,
      items: items,
      preview: localReviewAutoPolicyPreview(items: items),
      mergeMethod: .squash
    )
  }
  return dashboardReviewActionConfirmation(
    for: action,
    items: items,
    preview: localReviewActionPreview(action.previewKind, items: items),
    mergeMethod: .squash
  )
}

func dashboardReviewActionConfirmation(
  for action: DashboardReviewAttentionActionKind,
  items: [ReviewItem],
  preview: ReviewsActionPreviewResponse,
  mergeMethod: TaskBoardGitHubMergeMethod
) -> DashboardReviewActionConfirmation? {
  let needsAttention = items.contains(where: \.requiresAttention)
  let needsBatchConfirmation = items.count > 1 && (action == .merge || action == .auto)
  let hasPreviewWarnings = preview.skippedCount > 0 || !preview.warnings.isEmpty
  guard needsAttention || needsBatchConfirmation || hasPreviewWarnings else { return nil }
  let destructiveMerge =
    action == .merge
    && items.contains(where: \.requiresAdminMergeForRequiredFailures)
  let confirmTitle = dashboardReviewActionConfirmButtonTitle(
    for: action,
    actionableCount: preview.actionableCount,
    destructiveMerge: destructiveMerge
  )
  return DashboardReviewActionConfirmation(
    action: action,
    pullRequestIDs: items.map(\.pullRequestID),
    title: dashboardReviewActionConfirmationTitle(
      for: action,
      itemCount: items.count,
      destructiveMerge: destructiveMerge
    ),
    message: dashboardReviewActionConfirmationMessage(
      for: action,
      items: items,
      preview: preview,
      mergeMethod: mergeMethod,
      destructiveMerge: destructiveMerge
    ),
    confirmButtonTitle: confirmTitle,
    confirmRole: destructiveMerge || action == .merge ? .destructive : nil
  )
}

func dashboardReviewActionConfirmation(
  for action: DashboardReviewAttentionActionKind,
  items: [ReviewItem],
  preview: DashboardReviewsAutoPolicyPreview,
  mergeMethod: TaskBoardGitHubMergeMethod
) -> DashboardReviewActionConfirmation? {
  guard action == .auto else { return nil }
  let needsAttention = items.contains(where: \.requiresAttention)
  guard needsAttention || preview.requiresConfirmation else { return nil }
  return DashboardReviewActionConfirmation(
    action: action,
    pullRequestIDs: items.map(\.pullRequestID),
    title: dashboardReviewActionConfirmationTitle(
      for: action,
      itemCount: items.count,
      destructiveMerge: false
    ),
    message: dashboardReviewAutoPolicyConfirmationMessage(
      items: items,
      preview: preview,
      mergeMethod: mergeMethod
    ),
    confirmButtonTitle: dashboardReviewActionConfirmButtonTitle(
      for: action,
      actionableCount: preview.actionableCount,
      destructiveMerge: false
    ),
    confirmRole: nil
  )
}

private func dashboardReviewActionConfirmationTitle(
  for action: DashboardReviewAttentionActionKind,
  itemCount: Int,
  destructiveMerge: Bool
) -> String {
  if destructiveMerge {
    return itemCount == 1
      ? "Merge as Admin despite required failing checks?"
      : "Merge \(itemCount) pull requests as Admin despite required failing checks?"
  }
  let verb =
    switch action {
    case .approve: "Approve"
    case .merge: "Merge"
    case .auto: "Start auto policy on"
    }
  return itemCount == 1
    ? "\(verb) pull request that needs attention?"
    : "\(verb) \(itemCount) pull requests that need attention?"
}

private func dashboardReviewActionConfirmButtonTitle(
  for action: DashboardReviewAttentionActionKind,
  actionableCount: Int,
  destructiveMerge: Bool
) -> String {
  let countLabel = actionableCount == 1 ? "1 Pull Request" : "\(actionableCount) Pull Requests"
  switch action {
  case .approve:
    return "Approve \(countLabel)"
  case .merge where destructiveMerge:
    return actionableCount == 1 ? "Merge as Admin" : "Merge \(countLabel) as Admin"
  case .merge:
    return "Merge \(countLabel)"
  case .auto:
    return "Start Auto Policy on \(countLabel)"
  }
}
