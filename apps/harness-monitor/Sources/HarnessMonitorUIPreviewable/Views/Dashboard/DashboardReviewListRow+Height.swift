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
  }

  /// Conservative character cap used to predict whether the title will wrap
  /// to two lines at the typical Reviews-pane width. Below the cap the row
  /// stays at one title line; above it (or with a manual newline) the row
  /// pre-allocates the second line so wrapping doesn't shift sibling rows
  /// the first time SwiftUI lays them out.
  ///
  /// The cap was eyeballed for the narrow dashboard column (~340 pt
  /// effective title width after the status icon, avatar, and change pill
  /// take their cut). It is intentionally conservative: a couple of
  /// false-positive 2-line rows on short titles cost a small height bump,
  /// while a false-negative on a wrapping title causes a visible content
  /// jump as the row resolves its real height. Bias toward false positives.
  static let titleWrapCharacterThreshold = 32

  static func titleLikelyWraps(_ title: String) -> Bool {
    if title.contains("\n") { return true }
    return title.count > titleWrapCharacterThreshold
  }

  static func idealHeight(_ layout: Layout) -> CGFloat {
    var components: [CGFloat] = []
    let titleLines: CGFloat = layout.hasWrappedTitle ? 2 : 1
    components.append(layout.titleLineHeight * titleLines)
    if layout.hasSecondaryLine { components.append(layout.captionLineHeight) }
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
