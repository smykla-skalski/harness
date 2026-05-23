import HarnessMonitorKit
import SwiftUI

/// Reviewer summary mini-pill rendered on the row's status line.
///
/// Shows `"N/M approvals"` derived from `item.reviews` where:
/// - `N` = unique reviewers whose latest review state is `.approved`
/// - `M` = unique reviewer count across the review list
///
/// `M == 0` -> hides the pill entirely; we don't display "0/0".
/// Once Unit 10 lands the shared `DashboardReviewReviewerSummaryPill`
/// component, this companion is the seam to swap to it (the view is
/// the row's only call site, computed in one place).
struct DashboardReviewListRowReviewerSummary: View {
  let item: ReviewItem

  private var summary: DashboardReviewListRowReviewerSummaryData? {
    DashboardReviewListRowReviewerSummaryData(reviews: item.reviews)
  }

  var body: some View {
    if let summary {
      DashboardReviewStatusPill(
        label: "\(summary.approved)/\(summary.unique) approvals",
        tint: summary.tint,
        isQuiet: true
      )
      .accessibilityLabel(
        "\(summary.approved) of \(summary.unique) reviewers approved"
      )
    }
  }
}

/// Pure-data reviewer summary - keeps the row view free of business logic
/// and lets `DashboardReviewListRowReviewerSummaryTests` (in
/// `DashboardReviewListRowSecondaryTextTests.swift`) exercise the
/// derivation without spinning up a SwiftUI host.
struct DashboardReviewListRowReviewerSummaryData {
  let approved: Int
  let unique: Int

  init?(reviews: [PullRequestReview]) {
    guard !reviews.isEmpty else { return nil }
    var latestByAuthor: [String: ReviewReviewEventState] = [:]
    for review in reviews {
      latestByAuthor[review.author] = review.state
    }
    let uniqueCount = latestByAuthor.count
    guard uniqueCount > 0 else { return nil }
    self.unique = uniqueCount
    self.approved = latestByAuthor.values.count { $0 == .approved }
  }

  var tint: Color {
    if unique == 0 { return HarnessMonitorTheme.secondaryInk }
    if approved == unique { return HarnessMonitorTheme.success }
    if approved == 0 { return HarnessMonitorTheme.secondaryInk }
    return HarnessMonitorTheme.accent
  }
}
