import HarnessMonitorKit
import SwiftUI

enum DashboardDependencyAttentionActionKind {
  case approve
  case merge
  case auto

  var previewKind: DependencyUpdateActionPreviewKind {
    switch self {
    case .approve: .approve
    case .merge: .merge
    case .auto: .auto
    }
  }
}

enum DashboardDependencyAttentionBadgeKind: String, Identifiable {
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

struct DashboardDependencyActionConfirmation {
  let action: DashboardDependencyAttentionActionKind
  let pullRequestIDs: [String]
  let title: String
  let message: String
  let confirmButtonTitle: String
  let confirmRole: ButtonRole?
}

func dashboardDependencyApproveProminence(
  for items: [DependencyUpdateItem]
) -> DashboardDependencyActionProminence {
  items.contains(where: \.requiresAttention) ? .warning : .primary
}

func dashboardDependencyMergeProminence(
  for items: [DependencyUpdateItem]
) -> DashboardDependencyActionProminence {
  if items.contains(where: \.requiresAdminMergeForRequiredFailures) {
    return .destructive
  }
  if items.contains(where: \.requiresAttention) {
    return .warning
  }
  return .success
}

func dashboardDependencyMergeActionTitle(for items: [DependencyUpdateItem]) -> String {
  items.contains(where: \.requiresAdminMergeForRequiredFailures) ? "Merge as Admin" : "Merge"
}

func dashboardDependencyAttentionBadgeKinds(
  for item: DependencyUpdateItem
) -> [DashboardDependencyAttentionBadgeKind] {
  var badges: [DashboardDependencyAttentionBadgeKind] = []
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

func dashboardDependencyActionConfirmation(
  for action: DashboardDependencyAttentionActionKind,
  items: [DependencyUpdateItem]
) -> DashboardDependencyActionConfirmation? {
  dashboardDependencyActionConfirmation(
    for: action,
    items: items,
    preview: localDependencyActionPreview(action.previewKind, items: items),
    mergeMethod: .squash
  )
}

func dashboardDependencyActionConfirmation(
  for action: DashboardDependencyAttentionActionKind,
  items: [DependencyUpdateItem],
  preview: DependencyUpdatesActionPreviewResponse,
  mergeMethod: TaskBoardGitHubMergeMethod
) -> DashboardDependencyActionConfirmation? {
  let needsAttention = items.contains(where: \.requiresAttention)
  let needsBatchConfirmation = items.count > 1 && (action == .merge || action == .auto)
  let hasPreviewWarnings = preview.skippedCount > 0 || !preview.warnings.isEmpty
  guard needsAttention || needsBatchConfirmation || hasPreviewWarnings else { return nil }
  let destructiveMerge =
    action == .merge
    && items.contains(where: \.requiresAdminMergeForRequiredFailures)
  let confirmTitle = dashboardDependencyActionConfirmButtonTitle(
    for: action,
    actionableCount: preview.actionableCount,
    destructiveMerge: destructiveMerge
  )
  return DashboardDependencyActionConfirmation(
    action: action,
    pullRequestIDs: items.map(\.pullRequestID),
    title: dashboardDependencyActionConfirmationTitle(
      for: action,
      itemCount: items.count,
      destructiveMerge: destructiveMerge
    ),
    message: dashboardDependencyActionConfirmationMessage(
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

private func dashboardDependencyActionConfirmationTitle(
  for action: DashboardDependencyAttentionActionKind,
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

private func dashboardDependencyActionConfirmButtonTitle(
  for action: DashboardDependencyAttentionActionKind,
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

private func dashboardDependencyActionConfirmationMessage(
  for action: DashboardDependencyAttentionActionKind,
  items: [DependencyUpdateItem],
  preview: DependencyUpdatesActionPreviewResponse,
  mergeMethod: TaskBoardGitHubMergeMethod,
  destructiveMerge: Bool
) -> String {
  let subject = items.count == 1 ? "This pull request" : "These \(items.count) pull requests"
  var paragraphs: [String] = []
  if destructiveMerge {
    paragraphs.append(
      items.count == 1
        ? "This pull request can only be merged with admin permissions because required checks are failing."
        : "Some selected pull requests can only be merged with admin permissions because required checks are failing."
    )
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
      "Auto mode will approve or merge eligible dependency updates using \(mergeMethod.title)."
    )
  } else {
    paragraphs.append(
      items.count == 1
        ? "This pull request still needs attention before a normal merge."
        : "\(subject) still need attention before a normal merge."
    )
  }
  paragraphs.append(dashboardDependencyActionPreviewMessage(preview))
  if let summary = dashboardDependencyAttentionSelectionSummary(for: action, items: items) {
    paragraphs.append(summary)
  } else {
    paragraphs.append(contentsOf: dashboardDependencyAttentionReasonMessages(for: items))
  }
  return paragraphs.joined(separator: "\n\n")
}

private func dashboardDependencyAttentionSelectionSummary(
  for action: DashboardDependencyAttentionActionKind,
  items: [DependencyUpdateItem]
) -> String? {
  guard items.count > 1 else { return nil }
  let summaryLines = dashboardDependencyAttentionSummaryLines(for: action, items: items)
  guard !summaryLines.isEmpty else { return nil }
  return "Selection summary:\n• " + summaryLines.joined(separator: "\n• ")
}

private func dashboardDependencyAttentionSummaryLines(
  for action: DashboardDependencyAttentionActionKind,
  items: [DependencyUpdateItem]
) -> [String] {
  var lines: [String] = []
  if action == .merge {
    let adminBypass = items.filter(\.requiresAdminMergeForRequiredFailures).count
    if adminBypass > 0 {
      lines.append(
        dashboardDependencyCountMessage(
          count: adminBypass,
          singular: "selected PR can only merge with admin permissions.",
          plural: "selected PRs can only merge with admin permissions."
        )
      )
    }
  }
  lines.append(contentsOf: dashboardDependencyAttentionReasonMessages(for: items))
  return lines
}

private func dashboardDependencyActionPreviewMessage(
  _ preview: DependencyUpdatesActionPreviewResponse
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

private func dashboardDependencyAttentionReasonMessages(
  for items: [DependencyUpdateItem]
) -> [String] {
  guard !items.isEmpty else { return [] }
  if items.count == 1, let item = items.first {
    return dashboardDependencyAttentionReasonMessages(for: item)
  }
  var messages: [String] = []
  var requiredFailures = 0
  var optionalFailures = 0
  var policyBlocked = 0
  var changesRequested = 0
  var conflicts = 0
  for item in items {
    if item.hasRequiredFailedChecks {
      requiredFailures += 1
    } else if item.checkStatus == .failure {
      optionalFailures += 1
    }
    if item.policyBlocked {
      policyBlocked += 1
    }
    if item.reviewStatus == .changesRequested {
      changesRequested += 1
    }
    if item.mergeable == .conflicting {
      conflicts += 1
    }
  }
  if requiredFailures > 0 {
    messages.append(
      dashboardDependencyCountMessage(
        count: requiredFailures,
        singular: "selected PR has failing required checks.",
        plural: "selected PRs have failing required checks."
      )
    )
  }
  if optionalFailures > 0 {
    messages.append(
      dashboardDependencyCountMessage(
        count: optionalFailures,
        singular: "selected PR has failing checks that are not marked required.",
        plural: "selected PRs have failing checks that are not marked required."
      )
    )
  }
  if policyBlocked > 0 {
    messages.append(
      dashboardDependencyCountMessage(
        count: policyBlocked,
        singular: "selected PR is blocked by dependency policy.",
        plural: "selected PRs are blocked by dependency policy."
      )
    )
  }
  if changesRequested > 0 {
    messages.append(
      dashboardDependencyCountMessage(
        count: changesRequested,
        singular: "selected PR has changes requested.",
        plural: "selected PRs have changes requested."
      )
    )
  }
  if conflicts > 0 {
    messages.append(
      dashboardDependencyCountMessage(
        count: conflicts,
        singular: "selected PR has merge conflicts.",
        plural: "selected PRs have merge conflicts."
      )
    )
  }
  return messages
}

private func dashboardDependencyAttentionReasonMessages(
  for item: DependencyUpdateItem
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
    messages.append("Dependency policy is blocking this pull request.")
  }
  if item.reviewStatus == .changesRequested {
    messages.append("A reviewer requested changes.")
  }
  if item.mergeable == .conflicting {
    messages.append("This pull request has merge conflicts.")
  }
  return messages
}

private func dashboardDependencyCountMessage(
  count: Int,
  singular: String,
  plural: String
) -> String {
  count == 1 ? "1 \(singular)" : "\(count) \(plural)"
}
