import CoreGraphics

enum SessionWindowFontScale {
  static let minimumMetricsScale: CGFloat = 0.85
  static let maximumMetricsScale: CGFloat = 1.8

  static func metricsScale(for fontScale: CGFloat) -> CGFloat {
    min(max(fontScale, minimumMetricsScale), maximumMetricsScale)
  }
}
