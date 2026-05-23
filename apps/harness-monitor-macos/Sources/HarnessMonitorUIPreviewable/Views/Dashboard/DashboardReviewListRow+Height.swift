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
  static func idealHeight(
    titleLineHeight: CGFloat,
    captionLineHeight: CGFloat,
    pillStripHeight: CGFloat,
    hasAttentionStrip: Bool,
    hasRequiredFailedChecks: Bool,
    hasLabels: Bool,
    verticalPadding: CGFloat,
    lineSpacing: CGFloat
  ) -> CGFloat {
    var components: [CGFloat] = []
    // Title line + secondary line + status line are always rendered.
    components.append(titleLineHeight)
    components.append(captionLineHeight)
    components.append(pillStripHeight)
    if hasAttentionStrip { components.append(pillStripHeight) }
    if hasRequiredFailedChecks { components.append(pillStripHeight) }
    if hasLabels { components.append(pillStripHeight) }

    let lineCount = CGFloat(components.count)
    let spacingTotal = max(0, lineCount - 1) * lineSpacing
    let contentTotal = components.reduce(0, +)
    return contentTotal + spacingTotal + verticalPadding * 2
  }
}
