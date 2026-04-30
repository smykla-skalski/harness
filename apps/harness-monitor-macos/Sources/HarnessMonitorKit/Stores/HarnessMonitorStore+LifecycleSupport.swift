import Foundation

extension HarnessMonitorStore {
  func fallbackTimelineWindow(for timeline: [TimelineEntry]) -> TimelineWindowResponse? {
    guard !timeline.isEmpty else {
      return nil
    }
    return TimelineWindowResponse.fallbackMetadata(for: timeline)
  }

  func selectedTimelineRequestLimit(
    loadedTimeline: [TimelineEntry],
    timelineWindow: TimelineWindowResponse?
  ) -> Int {
    if loadedTimeline.isEmpty == false {
      return max(Self.initialSelectedTimelineWindowLimit, loadedTimeline.count)
    }
    return max(Self.initialSelectedTimelineWindowLimit, timelineWindow?.pageSize ?? 0)
  }

  func normalizedTimelineWindow(
    _ timelineWindow: TimelineWindowResponse?,
    loadedTimeline: [TimelineEntry]
  ) -> TimelineWindowResponse? {
    guard let timelineWindow else {
      return fallbackTimelineWindow(for: loadedTimeline)
    }

    return TimelineWindowResponse(
      revision: timelineWindow.revision,
      totalCount: max(timelineWindow.totalCount, loadedTimeline.count),
      windowStart: 0,
      windowEnd: loadedTimeline.count,
      hasOlder: loadedTimeline.count < timelineWindow.totalCount,
      hasNewer: false,
      oldestCursor: loadedTimeline.last.map(\.timelineCursor),
      newestCursor: loadedTimeline.first.map(\.timelineCursor),
      entries: nil,
      unchanged: timelineWindow.unchanged
    )
  }

  func previewReadySessionID(
    client: any HarnessMonitorClientProtocol,
    sessions: [SessionSummary]
  ) -> String? {
    guard
      selectedSessionID == nil,
      let previewClient = client as? PreviewHarnessClient,
      let readySessionID = previewClient.readySessionID,
      sessions.contains(where: { $0.sessionId == readySessionID })
    else {
      return nil
    }

    return readySessionID
  }

  @discardableResult
  public func presentSuccessFeedback(_ message: String) -> UUID {
    toast.presentSuccess(message)
  }

  @discardableResult
  public func presentFailureFeedback(_ message: String) -> UUID {
    toast.presentFailure(message)
  }

  public func dismissFeedback(id: UUID) {
    toast.dismiss(id: id)
  }
}
