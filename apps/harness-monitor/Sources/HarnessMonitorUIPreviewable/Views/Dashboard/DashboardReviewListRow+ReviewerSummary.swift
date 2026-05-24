import HarnessMonitorKit
import SwiftUI

/// Row-level wrapper that consumes the shared `DashboardReviewerSummaryPill`
/// from Unit 10's visual atoms set. The wrapper keeps the row's own view
/// name stable for accessibility/test discovery while the inner pill owns
/// the label, tint, and `.help` copy via `DashboardReviewerSummary`.
struct DashboardReviewListRowReviewerSummary: View {
  let item: ReviewItem

  var body: some View {
    let aggregate = DashboardReviewerSummary(reviews: item.reviews)
    if aggregate.reviewerCount > 0 {
      DashboardReviewerSummaryPill(summary: aggregate)
    }
  }
}
