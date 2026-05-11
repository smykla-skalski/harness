import SwiftUI

enum SessionTimelineRailRole: Equatable, Sendable {
  case middle
  case first
  case last
  case only

  static func role<ID: Equatable>(
    for id: ID,
    firstID: ID?,
    lastID: ID?
  ) -> Self {
    let isFirst = id == firstID
    let isLast = id == lastID
    switch (isFirst, isLast) {
    case (true, true): return .only
    case (true, false): return .first
    case (false, true): return .last
    case (false, false): return .middle
    }
  }
}

struct SessionTimelineRailEndpoints: Equatable, Sendable {
  var firstDotY: CGFloat?
  var lastDotY: CGFloat?

  // Merges non-nil values from `other` over self. Keeps cached values when the
  // first/last row is deallocated by LazyVStack on scroll, so the rail does not
  // collapse when its endpoint rows leave the viewport.
  func merging(_ other: Self) -> Self {
    var merged = self
    if let y = other.firstDotY { merged.firstDotY = y }
    if let y = other.lastDotY { merged.lastDotY = y }
    return merged
  }

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

struct SessionTimelineRailEndpointsKey: PreferenceKey {
  static let defaultValue = SessionTimelineRailEndpoints()

  static func reduce(
    value: inout SessionTimelineRailEndpoints,
    nextValue: () -> SessionTimelineRailEndpoints
  ) {
    let next = nextValue()
    if let y = next.firstDotY {
      value.firstDotY = value.firstDotY.map { min($0, y) } ?? y
    }
    if let y = next.lastDotY {
      value.lastDotY = value.lastDotY.map { max($0, y) } ?? y
    }
  }
}

extension EnvironmentValues {
  @Entry var sessionTimelineRailRole: SessionTimelineRailRole = .middle
}

enum SessionTimelineRailCoordinateSpace {
  static let name = "harness.monitor.timeline.rail"
}
