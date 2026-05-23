import Foundation

/// Row-height calculator for `DashboardReviewListRow`.
///
/// The row stays stable in height across content variants by stacking known
/// line heights instead of letting `HarnessMonitorWrapLayout` set the row's
/// natural size (item 34). Optional rows (`attention strip`, required failed
/// checks, labels strip) each add a fixed-cost pill-strip height when present.
///
/// Heights are passed in by the row's `@ScaledMetric` values so Dynamic Type
/// flows through to the final ideal-height value.
enum DashboardReviewListRowHeight {
  struct Layout {
    let titleLineHeight: CGFloat
    let captionLineHeight: CGFloat
    let pillStripHeight: CGFloat
    let hasAttentionStrip: Bool
    let hasRequiredFailedChecks: Bool
    let hasLabels: Bool
    let verticalPadding: CGFloat
    let lineSpacing: CGFloat
  }

  static func idealHeight(_ layout: Layout) -> CGFloat {
    var components: [CGFloat] = []
    components.append(layout.titleLineHeight)
    components.append(layout.captionLineHeight)
    components.append(layout.pillStripHeight)
    if layout.hasAttentionStrip { components.append(layout.pillStripHeight) }
    if layout.hasRequiredFailedChecks { components.append(layout.pillStripHeight) }
    if layout.hasLabels { components.append(layout.pillStripHeight) }

    let lineCount = CGFloat(components.count)
    let spacingTotal = max(0, lineCount - 1) * layout.lineSpacing
    let contentTotal = components.reduce(0, +)
    return contentTotal + spacingTotal + layout.verticalPadding * 2
  }
}
