import HarnessMonitorKit
import SwiftUI

enum DashboardDependencyAttentionActionKind {
  case approve
  case merge
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

func dashboardDependencyActionConfirmation(
  for action: DashboardDependencyAttentionActionKind,
  items: [DependencyUpdateItem]
) -> DashboardDependencyActionConfirmation? {
  guard items.contains(where: \.requiresAttention) else { return nil }
  let destructiveMerge =
    action == .merge
    && items.contains(where: \.requiresAdminMergeForRequiredFailures)
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
      destructiveMerge: destructiveMerge
    ),
    confirmButtonTitle: action == .approve ? "Approve Anyway" : "Merge Anyway",
    confirmRole: destructiveMerge ? .destructive : nil
  )
}

private func dashboardDependencyActionConfirmationTitle(
  for action: DashboardDependencyAttentionActionKind,
  itemCount: Int,
  destructiveMerge: Bool
) -> String {
  if destructiveMerge {
    return itemCount == 1
      ? "Merge despite required failing checks?"
      : "Merge \(itemCount) pull requests despite required failing checks?"
  }
  let verb = action == .approve ? "Approve" : "Merge"
  return itemCount == 1
    ? "\(verb) pull request that needs attention?"
    : "\(verb) \(itemCount) pull requests that need attention?"
}

private func dashboardDependencyActionConfirmationMessage(
  for action: DashboardDependencyAttentionActionKind,
  items: [DependencyUpdateItem],
  destructiveMerge: Bool
) -> String {
  let subject = items.count == 1 ? "This pull request" : "These \(items.count) pull requests"
  var paragraphs: [String] = []
  if destructiveMerge {
    paragraphs.append(
      "\(subject) cannot be merged normally because required checks are failing."
    )
    paragraphs.append(
      "Your GitHub permissions can bypass branch protections and merge immediately."
    )
  } else if action == .approve {
    paragraphs.append(
      items.count == 1
        ? "This pull request still needs attention before approval."
        : "\(subject) still need attention before approval."
    )
  } else {
    paragraphs.append(
      items.count == 1
        ? "This pull request still needs attention before a normal merge."
        : "\(subject) still need attention before a normal merge."
    )
  }
  paragraphs.append(contentsOf: dashboardDependencyAttentionReasonMessages(for: items))
  return paragraphs.joined(separator: "\n\n")
}

private func dashboardDependencyAttentionReasonMessages(
  for items: [DependencyUpdateItem]
) -> [String] {
  guard !items.isEmpty else { return [] }
  if items.count == 1, let item = items.first {
    return dashboardDependencyAttentionReasonMessages(for: item)
  }
  var messages: [String] = []
  let requiredFailures = items.filter(\.hasRequiredFailedChecks).count
  if requiredFailures > 0 {
    messages.append(
      dashboardDependencyCountMessage(
        count: requiredFailures,
        singular: "selected PR has failing required checks.",
        plural: "selected PRs have failing required checks."
      )
    )
  }
  let optionalFailures = items.filter { $0.checkStatus == .failure && !$0.hasRequiredFailedChecks }
    .count
  if optionalFailures > 0 {
    messages.append(
      dashboardDependencyCountMessage(
        count: optionalFailures,
        singular: "selected PR has failing checks that are not marked required.",
        plural: "selected PRs have failing checks that are not marked required."
      )
    )
  }
  let policyBlocked = items.filter(\.policyBlocked).count
  if policyBlocked > 0 {
    messages.append(
      dashboardDependencyCountMessage(
        count: policyBlocked,
        singular: "selected PR is blocked by dependency policy.",
        plural: "selected PRs are blocked by dependency policy."
      )
    )
  }
  let changesRequested = items.filter { $0.reviewStatus == .changesRequested }.count
  if changesRequested > 0 {
    messages.append(
      dashboardDependencyCountMessage(
        count: changesRequested,
        singular: "selected PR has changes requested.",
        plural: "selected PRs have changes requested."
      )
    )
  }
  let conflicts = items.filter { $0.mergeable == .conflicting }.count
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
