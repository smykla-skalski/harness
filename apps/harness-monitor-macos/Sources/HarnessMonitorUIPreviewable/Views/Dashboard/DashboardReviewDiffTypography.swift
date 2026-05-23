import SwiftUI

enum DashboardReviewDiffTypography {
  static let basePointSize: CGFloat = 12

  static func pointSize(fontScale: CGFloat) -> CGFloat {
    basePointSize * fontScale
  }

  static func font(for fontScale: CGFloat) -> Font {
    .system(size: pointSize(fontScale: fontScale), design: .monospaced)
  }
}
