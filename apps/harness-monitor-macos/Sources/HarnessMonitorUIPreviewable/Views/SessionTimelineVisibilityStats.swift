struct SessionTimelineVisibilityStats: Equatable, Sendable {
  let visibleRowCount: Int
  let renderedRowCount: Int
  let loadedEventCount: Int
  let totalEventCount: Int
  let firstVisibleEventNumber: Int?
  let lastVisibleEventNumber: Int?
  let filteredMatchCount: Int?
  let firstVisibleMatchNumber: Int?
  let lastVisibleMatchNumber: Int?

  static let empty = Self(
    visibleRowCount: 0,
    renderedRowCount: 0,
    loadedEventCount: 0,
    totalEventCount: 0,
    firstVisibleEventNumber: nil,
    lastVisibleEventNumber: nil,
    filteredMatchCount: nil,
    firstVisibleMatchNumber: nil,
    lastVisibleMatchNumber: nil
  )

  init(
    visibleRowCount: Int,
    renderedRowCount: Int,
    loadedEventCount: Int,
    totalEventCount: Int,
    firstVisibleEventNumber: Int? = nil,
    lastVisibleEventNumber: Int? = nil,
    filteredMatchCount: Int? = nil,
    firstVisibleMatchNumber: Int? = nil,
    lastVisibleMatchNumber: Int? = nil
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
    self.filteredMatchCount = filteredMatchCount.map { max(0, $0) }
    let clampedFirstMatch = Self.clampedVisibleMatchNumber(
      firstVisibleMatchNumber,
      filteredMatchCount: self.filteredMatchCount
    )
    let clampedLastMatch = Self.clampedVisibleMatchNumber(
      lastVisibleMatchNumber ?? clampedFirstMatch,
      filteredMatchCount: self.filteredMatchCount
    )
    if let clampedFirstMatch, let clampedLastMatch {
      self.firstVisibleMatchNumber = min(clampedFirstMatch, clampedLastMatch)
      self.lastVisibleMatchNumber = max(clampedFirstMatch, clampedLastMatch)
    } else {
      self.firstVisibleMatchNumber = nil
      self.lastVisibleMatchNumber = nil
    }
  }

  var statusText: String {
    if let filteredMatchCount {
      guard filteredMatchCount > 0 else {
        return "0 matches"
      }
      guard let firstVisibleMatchNumber else {
        return "\(filteredMatchCount) matches"
      }
      guard let lastVisibleMatchNumber else {
        return "Showing \(firstVisibleMatchNumber) of \(filteredMatchCount) matches"
      }
      if firstVisibleMatchNumber == lastVisibleMatchNumber {
        return "Showing \(firstVisibleMatchNumber) of \(filteredMatchCount) matches"
      }
      return
        "Showing \(firstVisibleMatchNumber)-\(lastVisibleMatchNumber) of \(filteredMatchCount) matches"
    }
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
    if let filteredMatchCount {
      guard filteredMatchCount > 0 else {
        return "No matching timeline items"
      }
      guard let firstVisibleMatchNumber else {
        return "\(filteredMatchCount) matching timeline items"
      }
      guard let lastVisibleMatchNumber else {
        return "Showing matching timeline item \(firstVisibleMatchNumber) of \(filteredMatchCount)"
      }
      if firstVisibleMatchNumber == lastVisibleMatchNumber {
        return "Showing matching timeline item \(firstVisibleMatchNumber) of \(filteredMatchCount)"
      }
      return [
        "Showing matching timeline items",
        "\(firstVisibleMatchNumber) to \(lastVisibleMatchNumber)",
        "of \(filteredMatchCount)",
      ].joined(separator: " ")
    }
    guard totalEventCount > 0, let firstVisibleEventNumber else {
      return ""
    }
    guard let lastVisibleEventNumber else {
      return "Showing event \(firstVisibleEventNumber) of \(totalEventCount)"
    }
    if firstVisibleEventNumber == lastVisibleEventNumber {
      return "Showing event \(firstVisibleEventNumber) of \(totalEventCount)"
    }
    let visibleEventRange = "\(firstVisibleEventNumber) to \(lastVisibleEventNumber)"
    return "Showing events \(visibleEventRange) of \(totalEventCount)"
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

  private static func clampedVisibleMatchNumber(
    _ value: Int?,
    filteredMatchCount: Int?
  ) -> Int? {
    guard let value, let filteredMatchCount, filteredMatchCount > 0 else {
      return nil
    }
    return max(1, min(value, filteredMatchCount))
  }
}
