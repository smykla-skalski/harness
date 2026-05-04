struct SessionTimelineVisibilityStats: Equatable, Sendable {
  let visibleRowCount: Int
  let renderedRowCount: Int
  let loadedEventCount: Int
  let totalEventCount: Int
  let firstVisibleEventNumber: Int?
  let lastVisibleEventNumber: Int?

  static let empty = Self(
    visibleRowCount: 0,
    renderedRowCount: 0,
    loadedEventCount: 0,
    totalEventCount: 0,
    firstVisibleEventNumber: nil,
    lastVisibleEventNumber: nil
  )

  init(
    visibleRowCount: Int,
    renderedRowCount: Int,
    loadedEventCount: Int,
    totalEventCount: Int,
    firstVisibleEventNumber: Int? = nil,
    lastVisibleEventNumber: Int? = nil
  ) {
    self.visibleRowCount = max(0, visibleRowCount)
    self.renderedRowCount = max(0, renderedRowCount)
    self.loadedEventCount = max(0, loadedEventCount)
    self.totalEventCount = max(0, totalEventCount)
    let clampedFirst = Self.clampedVisibleEventNumber(
      firstVisibleEventNumber,
      totalEventCount: self.totalEventCount
    )
    let clampedLast = Self.clampedVisibleEventNumber(
      lastVisibleEventNumber ?? clampedFirst,
      totalEventCount: self.totalEventCount
    )
    if let clampedFirst, let clampedLast {
      self.firstVisibleEventNumber = min(clampedFirst, clampedLast)
      self.lastVisibleEventNumber = max(clampedFirst, clampedLast)
    } else {
      self.firstVisibleEventNumber = nil
      self.lastVisibleEventNumber = nil
    }
  }

  var statusText: String {
    guard totalEventCount > 0, let firstVisibleEventNumber else {
      return ""
    }
    guard let lastVisibleEventNumber else {
      return "Showing \(firstVisibleEventNumber) of \(totalEventCount)"
    }
    if firstVisibleEventNumber == lastVisibleEventNumber {
      return "Showing \(firstVisibleEventNumber) of \(totalEventCount)"
    }
    return "Showing \(firstVisibleEventNumber)-\(lastVisibleEventNumber) of \(totalEventCount)"
  }

  var accessibilityStatusText: String {
    guard totalEventCount > 0, let firstVisibleEventNumber else {
      return ""
    }
    guard let lastVisibleEventNumber else {
      return "Showing event \(firstVisibleEventNumber) of \(totalEventCount)"
    }
    if firstVisibleEventNumber == lastVisibleEventNumber {
      return "Showing event \(firstVisibleEventNumber) of \(totalEventCount)"
    }
    return "Showing events \(firstVisibleEventNumber) to \(lastVisibleEventNumber) of \(totalEventCount)"
  }

  private static func clampedVisibleEventNumber(
    _ value: Int?,
    totalEventCount: Int
  ) -> Int? {
    guard let value, totalEventCount > 0 else {
      return nil
    }
    return max(1, min(value, totalEventCount))
  }
}
