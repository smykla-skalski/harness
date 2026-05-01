struct SessionTimelineVisibilityStats: Equatable, Sendable {
  let visibleRowCount: Int
  let renderedRowCount: Int
  let loadedEventCount: Int
  let totalEventCount: Int

  static let empty = Self(
    visibleRowCount: 0,
    renderedRowCount: 0,
    loadedEventCount: 0,
    totalEventCount: 0
  )

  init(
    visibleRowCount: Int,
    renderedRowCount: Int,
    loadedEventCount: Int,
    totalEventCount: Int
  ) {
    self.visibleRowCount = max(0, visibleRowCount)
    self.renderedRowCount = max(0, renderedRowCount)
    self.loadedEventCount = max(0, loadedEventCount)
    self.totalEventCount = max(0, totalEventCount)
  }

  var statusText: String {
    if totalEventCount == 0 {
      return "Visible rows \(visibleRowCount)"
    }
    let eventText = "Loaded events \(loadedEventCount)/\(totalEventCount)"
    return "Visible rows \(visibleRowCount) | \(eventText)"
  }
}
