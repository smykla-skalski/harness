import HarnessMonitorKit
import SwiftUI

/// Row-level wrapper that consumes the shared `DashboardReviewerSummaryPill`
/// from Unit 10's visual atoms set. The wrapper keeps the row's own view
/// name stable for accessibility/test discovery while the inner pill owns
/// the label, tint, and `.help` copy via `DashboardReviewerSummary`.
struct DashboardReviewListRowReviewerSummary: View {
  let summary: DashboardReviewerSummary?
  let usesSelectedBackgroundContrast: Bool

  var body: some View {
    if let summary {
      DashboardReviewerSummaryPill(
        summary: summary,
        usesSelectedBackgroundContrast: usesSelectedBackgroundContrast
      )
    }
  }
}
