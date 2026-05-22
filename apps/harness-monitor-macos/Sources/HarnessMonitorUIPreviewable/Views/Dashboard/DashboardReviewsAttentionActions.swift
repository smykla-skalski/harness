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

  var id: String { rawValue }

  var label: String {
    switch self {
    case .requiredChecks:
      "Required checks"
    case .failingChecks:
      "Checks failing"
    case .changesRequested:
      "Changes requested"
    case .policyBlocked:
      "Policy blocked"
    case .mergeConflicts:
      "Merge conflicts"
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
      "arrow.triangle.branch"
    }
  }

  var tint: Color {
    switch self {
    case .requiredChecks, .changesRequested, .mergeConflicts:
      HarnessMonitorTheme.danger
    case .failingChecks, .policyBlocked:
      HarnessMonitorTheme.caution
    }
  }
}

struct DashboardReviewActionConfirmation {
  let action: DashboardReviewAttentionActionKind
  let pullRequestIDs: [String]
  let title: String
  let message: String
  let confirmButtonTitle: String
  let confirmRole: ButtonRole?
}

func dashboardReviewApproveProminence(
  for items: [ReviewItem]
) -> DashboardReviewActionProminence {
  items.contains(where: \.requiresAttention) ? .warning : .primary
}

func dashboardReviewMergeProminence(
  for items: [ReviewItem]
) -> DashboardReviewActionProminence {
  if items.contains(where: \.requiresAdminMergeForRequiredFailures) {
    return .destructive
  }
  if items.contains(where: \.requiresAttention) {
    return .warning
  }
  return .success
}

func dashboardReviewMergeActionTitle(for items: [ReviewItem]) -> String {
  items.contains(where: \.requiresAdminMergeForRequiredFailures) ? "Merge as Admin" : "Merge"
}

func dashboardReviewAttentionBadgeKinds(
  for item: ReviewItem
) -> [DashboardReviewAttentionBadgeKind] {
  var badges: [DashboardReviewAttentionBadgeKind] = []
  if item.hasRequiredFailedChecks {
    badges.append(.requiredChecks)
  } else if item.checkStatus == .failure {
    badges.append(.failingChecks)
  }
  if item.reviewStatus == .changesRequested {
    badges.append(.changesRequested)
  }
  if item.policyBlocked {
    badges.append(.policyBlocked)
  }
  if item.mergeable == .conflicting {
    badges.append(.mergeConflicts)
  }
  return badges
}

func dashboardReviewActionConfirmation(
  for action: DashboardReviewAttentionActionKind,
  items: [ReviewItem]
) -> DashboardReviewActionConfirmation? {
  dashboardReviewActionConfirmation(
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
    case .auto: "Run auto mode on"
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
    return "Run Auto on \(countLabel)"
  }
}

private func dashboardReviewActionConfirmationMessage(
  for action: DashboardReviewAttentionActionKind,
  items: [ReviewItem],
  preview: ReviewsActionPreviewResponse,
  mergeMethod: TaskBoardGitHubMergeMethod,
  destructiveMerge: Bool
) -> String {
  let subject = items.count == 1 ? "This pull request" : "These \(items.count) pull requests"
  var paragraphs: [String] = []
  if destructiveMerge {
    if items.count == 1 {
      paragraphs.append(
        "This pull request can only be merged with admin permissions because required checks are failing."
      )
    } else {
      paragraphs.append(
        "Some selected pull requests can only be merged with admin permissions "
          + "because required checks are failing."
      )
    }
    paragraphs.append(
      "Merge as Admin uses your GitHub permissions to bypass branch protections and merge immediately."
    )
  } else if action == .approve {
    paragraphs.append(
      items.count == 1
        ? "This pull request still needs attention before approval."
        : "\(subject) still need attention before approval."
    )
  } else if action == .auto {
    paragraphs.append(
      "Auto mode will approve or merge eligible reviews using \(mergeMethod.title)."
    )
  } else {
    paragraphs.append(
      items.count == 1
        ? "This pull request still needs attention before a normal merge."
        : "\(subject) still need attention before a normal merge."
    )
  }
  paragraphs.append(dashboardReviewActionPreviewMessage(preview))
  if let summary = dashboardReviewAttentionSelectionSummary(for: action, items: items) {
    paragraphs.append(summary)
  } else {
    paragraphs.append(contentsOf: dashboardReviewAttentionReasonMessages(for: items))
  }
  return paragraphs.joined(separator: "\n\n")
}

private func dashboardReviewAttentionSelectionSummary(
  for action: DashboardReviewAttentionActionKind,
  items: [ReviewItem]
) -> String? {
  guard items.count > 1 else { return nil }
  let summaryLines = dashboardReviewAttentionSummaryLines(for: action, items: items)
  guard !summaryLines.isEmpty else { return nil }
  return "Selection summary:\n• " + summaryLines.joined(separator: "\n• ")
}

private func dashboardReviewAttentionSummaryLines(
  for action: DashboardReviewAttentionActionKind,
  items: [ReviewItem]
) -> [String] {
  var lines: [String] = []
  if action == .merge {
    let adminBypass = items.filter(\.requiresAdminMergeForRequiredFailures).count
    if adminBypass > 0 {
      lines.append(
        dashboardReviewCountMessage(
          count: adminBypass,
          singular: "selected PR can only merge with admin permissions.",
          plural: "selected PRs can only merge with admin permissions."
        )
      )
    }
  }
  lines.append(contentsOf: dashboardReviewAttentionReasonMessages(for: items))
  return lines
}

private func dashboardReviewActionPreviewMessage(
  _ preview: ReviewsActionPreviewResponse
) -> String {
  var lines = [
    "\(preview.actionableCount) of \(preview.totalCount) selected pull requests are eligible."
  ]
  if preview.skippedCount > 0 {
    var skippedReasonCounts: [String: Int] = [:]
    for target in preview.targets where !target.eligible {
      skippedReasonCounts[target.reason ?? "Unavailable", default: 0] += 1
    }
    let skippedReasons =
      skippedReasonCounts
      .map { reason, count in "\(count) \(reason)" }
      .sorted()
      .prefix(3)
      .joined(separator: "\n")
    lines.append("Skipping \(preview.skippedCount):\n\(skippedReasons)")
  }
  lines.append(contentsOf: preview.warnings)
  return lines.joined(separator: "\n")
}

private func dashboardReviewAttentionReasonMessages(
  for items: [ReviewItem]
) -> [String] {
  guard !items.isEmpty else { return [] }
  if items.count == 1, let item = items.first {
    return dashboardReviewAttentionReasonMessages(for: item)
  }
  var messages: [String] = []
  let counts = items.reduce(into: DashboardReviewAttentionReasonCounts()) { partial, item in
    partial.record(item)
  }
  if counts.requiredFailures > 0 {
    messages.append(
      dashboardReviewCountMessage(
        count: counts.requiredFailures,
        singular: "selected PR has failing required checks.",
        plural: "selected PRs have failing required checks."
      )
    )
  }
  if counts.optionalFailures > 0 {
    messages.append(
      dashboardReviewCountMessage(
        count: counts.optionalFailures,
        singular: "selected PR has failing checks that are not marked required.",
        plural: "selected PRs have failing checks that are not marked required."
      )
    )
  }
  if counts.policyBlocked > 0 {
    messages.append(
      dashboardReviewCountMessage(
        count: counts.policyBlocked,
        singular: "selected PR is blocked by review policy.",
        plural: "selected PRs are blocked by review policy."
      )
    )
  }
  if counts.changesRequested > 0 {
    messages.append(
      dashboardReviewCountMessage(
        count: counts.changesRequested,
        singular: "selected PR has changes requested.",
        plural: "selected PRs have changes requested."
      )
    )
  }
  if counts.conflicts > 0 {
    messages.append(
      dashboardReviewCountMessage(
        count: counts.conflicts,
        singular: "selected PR has merge conflicts.",
        plural: "selected PRs have merge conflicts."
      )
    )
  }
  return messages
}

private func dashboardReviewAttentionReasonMessages(
  for item: ReviewItem
) -> [String] {
  var messages: [String] = []
  if item.hasRequiredFailedChecks {
    messages.append(
      "Required checks failing: \(item.requiredFailedCheckNames.joined(separator: ", "))."
    )
  } else if item.checkStatus == .failure {
    messages.append("Checks are failing, but the failed checks are not marked required.")
  }
  if item.policyBlocked {
    messages.append("Review policy is blocking this pull request.")
  }
  if item.reviewStatus == .changesRequested {
    messages.append("A reviewer requested changes.")
  }
  if item.mergeable == .conflicting {
    messages.append("This pull request has merge conflicts.")
  }
  return messages
}

private func dashboardReviewCountMessage(
  count: Int,
  singular: String,
  plural: String
) -> String {
  count == 1 ? "1 \(singular)" : "\(count) \(plural)"
}
