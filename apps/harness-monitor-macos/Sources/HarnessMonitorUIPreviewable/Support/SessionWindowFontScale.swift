import SwiftUI

public enum SessionWindowFontScale {
  public static let storageKey = HarnessMonitorTextSize.storageKey
  public static let defaultScale: CGFloat = 1.0
  public static let minimumMetricsScale: CGFloat = 0.85
  public static let maximumMetricsScale: CGFloat = 1.8

  public static func normalizedTextSizeIndex(_ index: Int) -> Int {
    HarnessMonitorTextSize.normalizedIndex(index)
  }

  public static func scale(at textSizeIndex: Int) -> CGFloat {
    HarnessMonitorTextSize.scale(at: normalizedTextSizeIndex(textSizeIndex))
  }

  public static func metricsScale(for fontScale: CGFloat) -> CGFloat {
    min(max(fontScale, minimumMetricsScale), maximumMetricsScale)
  }
}

extension EnvironmentValues {
  @Entry public var sessionWindowFontScale: CGFloat = SessionWindowFontScale.defaultScale
}

extension View {
  public func sessionFontScale(_ scale: CGFloat) -> some View {
    environment(\.fontScale, scale)
      .environment(\.sessionWindowFontScale, scale)
  }

  public func sessionFontScale(textSizeIndex: Int) -> some View {
    sessionFontScale(SessionWindowFontScale.scale(at: textSizeIndex))
  }
}
