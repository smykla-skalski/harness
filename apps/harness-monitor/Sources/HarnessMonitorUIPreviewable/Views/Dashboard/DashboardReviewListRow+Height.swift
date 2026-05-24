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
    /// `true` when the row is judged likely to wrap its title to two lines
    /// at the current Reviews-pane width. The caller computes this via
    /// `titleLikelyWraps(_:)` before constructing the layout so the
    /// idealHeight hint accounts for the extra title line only when it's
    /// expected, not always. Short titles stay compact.
    let hasWrappedTitle: Bool
    let hasSecondaryLine: Bool
    let hasAttentionStrip: Bool
    let hasRequiredFailedChecks: Bool
    let hasLabels: Bool
    let verticalPadding: CGFloat
    let lineSpacing: CGFloat
    let statusLineHeight: CGFloat?
    let attentionStripHeight: CGFloat?
    let requiredFailedChecksHeight: CGFloat?
    let labelsStripHeight: CGFloat?

    init(
      titleLineHeight: CGFloat,
      captionLineHeight: CGFloat,
      pillStripHeight: CGFloat,
      hasWrappedTitle: Bool,
      hasSecondaryLine: Bool,
      hasAttentionStrip: Bool,
      hasRequiredFailedChecks: Bool,
      hasLabels: Bool,
      verticalPadding: CGFloat,
      lineSpacing: CGFloat,
      statusLineHeight: CGFloat? = nil,
      attentionStripHeight: CGFloat? = nil,
      requiredFailedChecksHeight: CGFloat? = nil,
      labelsStripHeight: CGFloat? = nil
    ) {
      self.titleLineHeight = titleLineHeight
      self.captionLineHeight = captionLineHeight
      self.pillStripHeight = pillStripHeight
      self.hasWrappedTitle = hasWrappedTitle
      self.hasSecondaryLine = hasSecondaryLine
      self.hasAttentionStrip = hasAttentionStrip
      self.hasRequiredFailedChecks = hasRequiredFailedChecks
      self.hasLabels = hasLabels
      self.verticalPadding = verticalPadding
      self.lineSpacing = lineSpacing
      self.statusLineHeight = statusLineHeight
      self.attentionStripHeight = attentionStripHeight
      self.requiredFailedChecksHeight = requiredFailedChecksHeight
      self.labelsStripHeight = labelsStripHeight
    }
  }

  static func titleLikelyWraps(_ title: String) -> Bool {
    title.contains("\n")
  }

  static func idealHeight(_ layout: Layout) -> CGFloat {
    var components: [CGFloat] = []
    let titleLines: CGFloat = layout.hasWrappedTitle ? 2 : 1
    components.append(layout.titleLineHeight * titleLines)
    if layout.hasSecondaryLine { components.append(layout.captionLineHeight) }
    components.append(layout.statusLineHeight ?? layout.pillStripHeight)
    if layout.hasAttentionStrip {
      components.append(layout.attentionStripHeight ?? layout.pillStripHeight)
    }
    if layout.hasRequiredFailedChecks {
      components.append(layout.requiredFailedChecksHeight ?? layout.pillStripHeight)
    }
    if layout.hasLabels {
      components.append(layout.labelsStripHeight ?? layout.pillStripHeight)
    }

    let lineCount = CGFloat(components.count)
    let spacingTotal = max(0, lineCount - 1) * layout.lineSpacing
    let contentTotal = components.reduce(0, +)
    return contentTotal + spacingTotal + layout.verticalPadding * 2
  }
}
