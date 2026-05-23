import HarnessMonitorKit
import SwiftUI

/// Muted chips that render `ReviewItem.labels` underneath the attention strip
/// in the Reviews route list row.
///
/// Each label uses `DashboardReviewStatusPill(isQuiet: true)` with the
/// `secondaryInk` tint so the chip family reads as informational rather than
/// signalling action. The strip caps the visible count at 6 and rolls the
/// remainder into a `+N more` chip so very label-heavy PRs don't blow up
/// row height.
struct DashboardReviewListRowLabelsStrip: View {
  let labels: [String]

  private let visibleCap = 6

  private var visible: [String] {
    Array(labels.prefix(visibleCap))
  }

  private var overflow: Int {
    max(0, labels.count - visibleCap)
  }

  var body: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingXS,
      lineSpacing: HarnessMonitorTheme.spacingXS
    ) {
      ForEach(visible, id: \.self) { label in
        DashboardReviewStatusPill(
          label: label,
          tint: HarnessMonitorTheme.secondaryInk,
          isQuiet: true
        )
      }
      if overflow > 0 {
        DashboardReviewStatusPill(
          label: "+\(overflow) more",
          tint: HarnessMonitorTheme.secondaryInk,
          isQuiet: true
        )
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    "Labels: \(labels.joined(separator: ", "))"
  }
}
