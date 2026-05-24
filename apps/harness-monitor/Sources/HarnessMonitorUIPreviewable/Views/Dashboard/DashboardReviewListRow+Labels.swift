import HarnessMonitorKit
import SwiftUI

/// Muted chips that render `ReviewItem.labels` underneath the attention strip
/// in the Reviews route list row.
///
/// Shares `DashboardReviewLabelChip` with the detail-pane label strip so the
/// two surfaces speak the same visual vocabulary. When the route view threads
/// the repository's label palette in via `repositoryLabels`, each chip picks
/// up its GitHub colour for the swatch dot, background tint, and border so
/// labels read at a glance instead of as a wall of identical greys. Labels
/// without a matching descriptor (cache miss, new label added since last
/// sync) fall back to the chip's neutral `secondaryInk` tier so the strip
/// still renders without flicker. The strip caps the visible count at 6 and
/// rolls the remainder into a `+N more` chip so very label-heavy PRs don't
/// blow up row height.
struct DashboardReviewListRowLabelsStrip: View {
  let labels: [String]
  let repositoryLabels: [ReviewRepositoryLabel]

  private static let visibleCap = 6
  private let visibleLabels: ArraySlice<String>
  private let overflow: Int
  private let labelByName: [String: ReviewRepositoryLabel]
  private let accessibilityLabelText: String

  init(labels: [String], repositoryLabels: [ReviewRepositoryLabel] = []) {
    self.labels = labels
    self.repositoryLabels = repositoryLabels
    visibleLabels = labels.prefix(Self.visibleCap)
    overflow = max(0, labels.count - Self.visibleCap)
    labelByName = Dictionary(
      repositoryLabels.map { ($0.name, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    accessibilityLabelText = "Labels: \(labels.joined(separator: ", "))"
  }

  var body: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingXS,
      lineSpacing: HarnessMonitorTheme.spacingXS
    ) {
      ForEach(visibleLabels, id: \.self) { label in
        DashboardReviewLabelChip(name: label, descriptor: labelByName[label])
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
    .accessibilityLabel(accessibilityLabelText)
  }
}
