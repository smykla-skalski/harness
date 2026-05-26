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
  let usesSelectedBackgroundContrast: Bool

  init(
    summary: DashboardReviewerSummary,
    usesSelectedBackgroundContrast: Bool = false
  ) {
    self.summary = summary
    self.usesSelectedBackgroundContrast = usesSelectedBackgroundContrast
  }

  init(
    reviews: [PullRequestReview],
    usesSelectedBackgroundContrast: Bool = false
  ) {
    self.init(
      summary: DashboardReviewerSummary(reviews: reviews),
      usesSelectedBackgroundContrast: usesSelectedBackgroundContrast
    )
  }

  var body: some View {
    DashboardReviewStatusPill(
      label: summary.label,
      tint: summary.tint,
      systemImage: "person.2",
      isQuiet: true,
      usesSelectedBackgroundContrast: usesSelectedBackgroundContrast,
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
    let core = PullRequestReviewerSummary(
      approvedCount: approvedCount,
      reviewerCount: reviewerCount
    )
    self.approvedCount = core.approvedCount
    self.reviewerCount = core.reviewerCount
  }

  init(reviews: [PullRequestReview]) {
    let core = PullRequestReviewerSummary(reviews: reviews)
    self.init(approvedCount: core.approvedCount, reviewerCount: core.reviewerCount)
  }

  var label: String {
    PullRequestReviewerSummary(
      approvedCount: approvedCount,
      reviewerCount: reviewerCount
    ).label
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
