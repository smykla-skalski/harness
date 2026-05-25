import AppKit
import SwiftUI

enum DashboardReviewDiffTypography {
  static let basePointSize: CGFloat = 12
  private static let verticalPadding: CGFloat = 3
  static let threadBadgeSize = CGSize(width: 20, height: 15)

  struct LayoutMetrics: Equatable {
    let lineTextHeight: CGFloat
    let rowHeight: CGFloat
    let textTopInset: CGFloat

    var textBottomInset: CGFloat {
      rowHeight - lineTextHeight - textTopInset
    }

    func textOriginY(in rect: NSRect) -> CGFloat {
      rect.minY + textTopInset
    }

    func baselineY(for glyphBounds: CGRect, in rect: NSRect) -> CGFloat {
      rect.minY + floor((rect.height - glyphBounds.height) / 2) + glyphBounds.maxY
    }

    func badgeRect(in rect: NSRect, x: CGFloat) -> NSRect {
      let badgeHeight = DashboardReviewDiffTypography.threadBadgeSize.height
      return NSRect(
        x: x,
        y: rect.minY + floor((rect.height - badgeHeight) / 2),
        width: DashboardReviewDiffTypography.threadBadgeSize.width,
        height: badgeHeight
      )
    }
  }

  static func pointSize(fontScale: CGFloat) -> CGFloat {
    basePointSize * fontScale
  }

  static func appKitFont(for fontScale: CGFloat) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: pointSize(fontScale: fontScale), weight: .regular)
  }

  /// Per-character advance for the monospaced diff font. Measured from a run and
  /// divided by its length so the value is the true layout advance the renderer
  /// uses, not a single glyph's bounding width, which can round the last column
  /// over the edge. Floored so a degenerate font can never collapse the budget.
  static func characterAdvance(for font: NSFont) -> CGFloat {
    let sampleLength = 64
    let runWidth = (String(repeating: "0", count: sampleLength) as NSString)
      .size(withAttributes: [.font: font]).width
    return max(6, runWidth / CGFloat(sampleLength))
  }

  static func lineTextHeight(for font: NSFont) -> CGFloat {
    max(12, ceil(("Ag" as NSString).size(withAttributes: [.font: font]).height))
  }

  static func rowHeight(for font: NSFont) -> CGFloat {
    layoutMetrics(for: font).rowHeight
  }

  static func rowHeight(fontScale: CGFloat) -> CGFloat {
    rowHeight(for: appKitFont(for: fontScale))
  }

  static func layoutMetrics(for font: NSFont) -> LayoutMetrics {
    let lineTextHeight = lineTextHeight(for: font)
    let rowHeight = max(18, lineTextHeight + verticalPadding * 2)
    let centeredInset = max(1, floor((rowHeight - lineTextHeight) / 2))
    let opticalLift = min(centeredInset - 1, max(0, floor((font.ascender - font.capHeight) / 2)))
    let textTopInset = max(1, centeredInset - opticalLift)
    return LayoutMetrics(
      lineTextHeight: lineTextHeight,
      rowHeight: rowHeight,
      textTopInset: textTopInset
    )
  }

  static func font(for fontScale: CGFloat) -> Font {
    .system(size: pointSize(fontScale: fontScale), design: .monospaced)
  }
}
