import AppKit
import SwiftUI

enum DashboardReviewDiffTypography {
  static let basePointSize: CGFloat = 12
  private static let verticalPadding: CGFloat = 3

  static func pointSize(fontScale: CGFloat) -> CGFloat {
    basePointSize * fontScale
  }

  static func appKitFont(for fontScale: CGFloat) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: pointSize(fontScale: fontScale), weight: .regular)
  }

  static func lineTextHeight(for font: NSFont) -> CGFloat {
    max(12, ceil(("Ag" as NSString).size(withAttributes: [.font: font]).height))
  }

  static func rowHeight(for font: NSFont) -> CGFloat {
    max(18, lineTextHeight(for: font) + verticalPadding * 2)
  }

  static func rowHeight(fontScale: CGFloat) -> CGFloat {
    rowHeight(for: appKitFont(for: fontScale))
  }

  static func font(for fontScale: CGFloat) -> Font {
    .system(size: pointSize(fontScale: fontScale), design: .monospaced)
  }
}
