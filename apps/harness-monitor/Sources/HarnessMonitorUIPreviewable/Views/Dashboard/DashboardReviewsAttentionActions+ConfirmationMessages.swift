import HarnessMonitorKit
import SwiftUI

func dashboardReviewActionConfirmationMessage(
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
      "Auto will start the configured Reviews policy workflow. "
        + "Merge steps use \(mergeMethod.title) when the policy reaches them."
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

func dashboardReviewAutoPolicyConfirmationMessage(
  items: [ReviewItem],
  preview: DashboardReviewsAutoPolicyPreview,
  mergeMethod: TaskBoardGitHubMergeMethod
) -> String {
  var paragraphs = [
    "Auto will start the configured Reviews policy workflow. "
      + "Eligible pull requests may approve, merge, or pause for timers/events "
      + "before continuing. Merge steps use \(mergeMethod.title)."
  ]
  paragraphs.append(
    dashboardReviewAutoPolicyPreviewMessage(
      preview,
      mergeMethod: mergeMethod
    )
  )
  if let summary = dashboardReviewAttentionSelectionSummary(for: .auto, items: items) {
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
