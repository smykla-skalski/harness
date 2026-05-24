import Foundation

/// Stable widget kind identifiers shared between the widget extension
/// (which registers the widget) and the App Intents that need to
/// invalidate a widget timeline after a mutating action. Both sides
/// must use the same literal; centralising it here removes the risk of
/// a Spotlight / Siri action approving a PR but the dock badge or
/// macOS widget showing the old count until the next 15-minute
/// timeline tick
public enum HarnessMonitorWidgetKinds {
  /// macOS `NeedsMeCountWidget` (small home-screen widget on macOS
  /// and the dock-tile companion)
  public static let needsMeCount = "needs-me-count"

  /// watchOS `NeedsMeCountWatchWidget` (Apple Watch accessory
  /// complications - circular, rectangular, inline)
  public static let needsMeCountWatch = "needs-me-count-watch"
}
