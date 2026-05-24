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
    /// Legacy two-line flag kept so existing tests and call sites can still
    /// describe the common wrapped/unwrapped shape. Prefer `titleLineCount`
    /// for new code paths that need more than two title lines.
    let hasWrappedTitle: Bool
    let titleLineCount: Int?
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
      titleLineCount: Int? = nil,
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
      self.titleLineCount = titleLineCount
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
    estimatedTitleLineCount(title, maximumLines: 2) > 1
  }

  static func estimatedTitleLineCount(_ title: String, maximumLines: Int) -> Int {
    let clampedMaximum = max(1, maximumLines)
    guard clampedMaximum > 1 else { return 1 }

    let explicitLineCount = title.split(
      separator: "\n",
      omittingEmptySubsequences: false
    ).count
    if explicitLineCount > 1 {
      return min(clampedMaximum, explicitLineCount)
    }

    let normalizedTitle = title
      .replacingOccurrences(
        of: #"\s+"#,
        with: " ",
        options: .regularExpression
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedTitle.isEmpty else { return 1 }

    let estimatedLines = Int(
      ceil(Double(normalizedTitle.count) / Double(Self.approximateCharactersPerLine))
    )
    return min(clampedMaximum, max(1, estimatedLines))
  }

  static func idealHeight(_ layout: Layout) -> CGFloat {
    var components: [CGFloat] = []
    let resolvedTitleLineCount = max(
      1,
      layout.titleLineCount ?? (layout.hasWrappedTitle ? 2 : 1)
    )
    let titleLines = CGFloat(resolvedTitleLineCount)
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

  private static let approximateCharactersPerLine = 44
}
