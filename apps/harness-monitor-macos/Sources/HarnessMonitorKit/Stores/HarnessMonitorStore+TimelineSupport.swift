import Foundation

extension HarnessMonitorStore {
  func selectedSessionChange(
    for current: SessionDetail?,
    next: SessionDetail
  ) -> SelectionSlice.Change {
    guard let current,
      current.session.sessionId == next.session.sessionId,
      current.session.status == next.session.status
    else {
      return .selectedSession
    }
    return .selectedSessionDetail
  }
}

extension TimelineEntry {
  var timelineCursor: TimelineCursor {
    TimelineCursor(recordedAt: recordedAt, entryId: entryId)
  }
}
