import SwiftUI

struct SessionTimelineRailEndpoints: Equatable, Sendable {
  var firstDotY: CGFloat?
  var lastDotY: CGFloat?

  // Computes (top, height) for the rail given the LazyVStack's content height,
  // falling back to spacingSM/spacingMD insets when an endpoint is not yet known.
  func railLayout(in contentHeight: CGFloat) -> (top: CGFloat, height: CGFloat) {
    let fallbackTop = HarnessMonitorTheme.spacingSM
    let fallbackBottom = max(fallbackTop, contentHeight - HarnessMonitorTheme.spacingMD)
    let topY = firstDotY ?? fallbackTop
    let bottomY = lastDotY ?? fallbackBottom
    let minY = min(topY, bottomY)
    let maxY = max(topY, bottomY)
    return (top: minY, height: max(0, maxY - minY))
  }
}

enum SessionTimelineRailCoordinateSpace {
  static let name = "harness.monitor.timeline.rail"
}
