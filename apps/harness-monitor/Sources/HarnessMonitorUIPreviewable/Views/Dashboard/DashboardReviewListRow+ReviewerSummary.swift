import AppKit
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
      Label(summary.compactLabel, systemImage: "person.2")
        .scaledFont(.caption2.weight(.medium))
        .foregroundStyle(
          reviewerSummaryForegroundColor(
            usesSelectedBackgroundContrast: usesSelectedBackgroundContrast
          )
        )
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .help(summary.expandedTitle)
        .accessibilityLabel(summary.expandedTitle)
    }
  }

  private func reviewerSummaryForegroundColor(
    usesSelectedBackgroundContrast: Bool
  ) -> Color {
    if usesSelectedBackgroundContrast {
      Color(nsColor: .alternateSelectedControlTextColor)
    } else {
      HarnessMonitorTheme.tertiaryInk
    }
  }
}
