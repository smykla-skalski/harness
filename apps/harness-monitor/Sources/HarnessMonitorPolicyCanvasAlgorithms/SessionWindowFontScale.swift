import CoreGraphics

public enum SessionWindowFontScale {
  public static let minimumMetricsScale: CGFloat = 0.85
  public static let maximumMetricsScale: CGFloat = 1.8

  public static func metricsScale(for fontScale: CGFloat) -> CGFloat {
    min(max(fontScale, minimumMetricsScale), maximumMetricsScale)
  }
}
