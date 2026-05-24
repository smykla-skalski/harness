import HarnessMonitorKit
import SwiftUI

/// Muted chips that render `ReviewItem.labels` underneath the attention strip
/// in the Reviews route list row.
///
/// Shares `DashboardReviewLabelChip` with the detail-pane label strip so the
/// two surfaces speak the same visual vocabulary. The row strip does not
/// have access to the repository label palette, so it renders without the
/// colour-swatch dot (`showsSwatch: false`) and falls back to the plain
/// `secondaryInk` background tier the chip already supports. The strip
/// caps the visible count at 6 and rolls the remainder into a `+N more`
/// chip so very label-heavy PRs don't blow up row height.
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
        DashboardReviewLabelChip(name: label, descriptor: nil, showsSwatch: false)
      }
      if overflow > 0 {
        DashboardReviewLabelChip(
          name: "+\(overflow) more",
          descriptor: nil,
          showsSwatch: false
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
