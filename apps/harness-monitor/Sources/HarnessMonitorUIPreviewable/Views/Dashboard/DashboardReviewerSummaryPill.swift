import HarnessMonitorKit
import SwiftUI

// Mini-pill summarising the approval count for a single review row.
// Owned by Unit 10's visual atoms set; Unit 1's row redesign consumes
// it via `DashboardReviewListRow+ReviewerSummary.swift`.

/// Compact reviewer-summary pill rendered next to the row status pill.
/// Shows "N/M approvals" where N = approvals submitted, M = total unique
/// reviewers seen on the PR. Tint follows the colour-role table:
/// - `.success`      -> N == M and N > 0 (every known reviewer approved).
/// - `.accent`       -> 0 < N < M (more approvals expected).
/// - `.secondaryInk` -> N == 0 (no approval activity yet).
struct DashboardReviewerSummaryPill: View {
  let summary: DashboardReviewerSummary

  init(summary: DashboardReviewerSummary) {
    self.summary = summary
  }

  init(reviews: [PullRequestReview]) {
    self.init(summary: DashboardReviewerSummary(reviews: reviews))
  }

  var body: some View {
    DashboardReviewStatusPill(
      label: summary.label,
      tint: summary.tint,
      systemImage: "person.2",
      isQuiet: true,
      help: summary.expandedTitle
    )
    .accessibilityLabel(summary.expandedTitle)
  }
}

/// Reviewer-summary aggregate computed from `PullRequestReview` rows on a
/// `ReviewItem`. Counts each reviewer once (last submitted state wins) so
/// repeated reviews from the same author do not inflate the totals.
struct DashboardReviewerSummary: Equatable {
  let approvedCount: Int
  let reviewerCount: Int

  init(approvedCount: Int, reviewerCount: Int) {
    self.approvedCount = max(0, min(approvedCount, max(0, reviewerCount)))
    self.reviewerCount = max(0, reviewerCount)
  }

  init(reviews: [PullRequestReview]) {
    var lastStateByAuthor: [String: ReviewReviewEventState] = [:]
    for review in reviews where !review.author.isEmpty {
      lastStateByAuthor[review.author] = review.state
    }
    let approved = lastStateByAuthor.values.count { $0 == .approved }
    self.init(approvedCount: approved, reviewerCount: lastStateByAuthor.count)
  }

  var label: String {
    "\(approvedCount)/\(reviewerCount) approvals"
  }

  var tint: Color {
    if reviewerCount == 0 {
      return HarnessMonitorTheme.secondaryInk
    }
    if approvedCount == reviewerCount {
      return HarnessMonitorTheme.success
    }
    if approvedCount > 0 {
      return HarnessMonitorTheme.accent
    }
    return HarnessMonitorTheme.secondaryInk
  }

  var expandedTitle: String {
    if reviewerCount == 0 {
      return "No reviews submitted yet"
    }
    let reviewerNoun = reviewerCount == 1 ? "reviewer" : "reviewers"
    return "\(approvedCount) of \(reviewerCount) \(reviewerNoun) approved"
  }
}
