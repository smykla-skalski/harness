import HarnessMonitorKit
import SwiftUI

func dashboardReviewAttentionReasonMessages(
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

func dashboardReviewAttentionReasonMessages(
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

func dashboardReviewCountMessage(
  count: Int,
  singular: String,
  plural: String
) -> String {
  count == 1 ? "1 \(singular)" : "\(count) \(plural)"
}
