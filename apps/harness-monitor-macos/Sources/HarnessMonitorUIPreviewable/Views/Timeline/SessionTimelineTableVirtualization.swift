import CoreGraphics

struct SessionTimelineTableVirtualization: Equatable {
  let totalCount: Int
  let windowStart: Int
  let windowEnd: Int
  let isFiltered: Bool

  static let disabled = Self(
    totalCount: 0,
    windowStart: 0,
    windowEnd: 0,
    isFiltered: true
  )

  init(
    totalCount: Int,
    windowStart: Int,
    windowEnd: Int,
    isFiltered: Bool
  ) {
    self.totalCount = max(0, totalCount)
    self.windowStart = max(0, windowStart)
    self.windowEnd = max(self.windowStart, min(max(0, totalCount), windowEnd))
    self.isFiltered = isFiltered
  }

  var isEnabled: Bool {
    !isFiltered && totalCount > 0 && (windowStart > 0 || windowEnd < totalCount)
  }

  var virtualRowHeight: CGFloat {
    SessionTimelineTableMetrics.estimatedBaseRowHeight
  }
}

struct SessionTimelineTableVirtualSpacers: Equatable {
  let topHeight: CGFloat
  let bottomHeight: CGFloat
  let documentHeight: CGFloat

  static let zero = Self(topHeight: 0, bottomHeight: 0, documentHeight: 0)

  var hasTop: Bool { topHeight > 0.5 }
  var hasBottom: Bool { bottomHeight > 0.5 }
}
