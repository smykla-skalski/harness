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
        DashboardReviewListRowLabelChip(label: label)
      }
      if overflow > 0 {
        DashboardReviewListRowLabelChip(label: "+\(overflow) more")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    "Labels: \(labels.joined(separator: ", "))"
  }
}

/// Dedicated chip for `ReviewItem.labels`. Splits the visual contract from
/// `DashboardReviewStatusPill` so labels can keep a quiet background tier
/// (secondary-tinted, ~10% opacity) while still rendering the label text in
/// the primary `ink` color. The previous implementation reused
/// `DashboardReviewStatusPill(tint: .secondaryInk)`, which painted both the
/// background AND the text in `secondaryInk` — leaving a grey-on-grey chip
/// that scanned as decorative noise instead of a legible tag.
struct DashboardReviewListRowLabelChip: View {
  let label: String

  var body: some View {
    Text(label)
      .scaledFont(.caption.weight(.semibold))
      .lineLimit(1)
      .foregroundStyle(HarnessMonitorTheme.ink)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background {
        RoundedRectangle(
          cornerRadius: HarnessMonitorTheme.pillCornerRadius,
          style: .continuous
        )
        .fill(HarnessMonitorTheme.secondaryInk.opacity(0.14))
      }
      .overlay {
        RoundedRectangle(
          cornerRadius: HarnessMonitorTheme.pillCornerRadius,
          style: .continuous
        )
        .strokeBorder(HarnessMonitorTheme.secondaryInk.opacity(0.32), lineWidth: 1)
      }
      .help(label)
  }
}
