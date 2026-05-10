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
    let preferredLimit =
      selectedTimelinePreferredWindowLimit ?? Self.initialSelectedTimelineWindowLimit
    if loadedTimeline.isEmpty == false {
      return max(preferredLimit, loadedTimeline.count)
    }
    return max(preferredLimit, timelineWindow?.pageSize ?? 0)
  }

  public func updateSelectedTimelinePreferredWindowLimit(_ limit: Int?) {
    let normalizedLimit = limit.map { max(1, $0) }
    guard selectedTimelinePreferredWindowLimit != normalizedLimit else {
      return
    }
    selectedTimelinePreferredWindowLimit = normalizedLimit
  }

  func normalizedTimelineWindow(
    _ timelineWindow: TimelineWindowResponse?,
    loadedTimeline: [TimelineEntry]
  ) -> TimelineWindowResponse? {
    guard let timelineWindow else {
      return fallbackTimelineWindow(for: loadedTimeline)
    }

    let totalCount = max(timelineWindow.totalCount, loadedTimeline.count)
    let preservesExplicitWindow = timelineWindow.windowStart > 0 || timelineWindow.hasNewer
    let windowStart =
      if preservesExplicitWindow {
        min(timelineWindow.windowStart, totalCount)
      } else {
        0
      }
    let windowEnd =
      if preservesExplicitWindow {
        min(totalCount, windowStart + loadedTimeline.count)
      } else {
        loadedTimeline.count
      }

    return TimelineWindowResponse(
      revision: timelineWindow.revision,
      totalCount: totalCount,
      windowStart: windowStart,
      windowEnd: windowEnd,
      hasOlder: timelineWindow.hasOlder || windowEnd < totalCount,
      hasNewer: timelineWindow.hasNewer || windowStart > 0,
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
  public func presentSuccessFeedback(
    _ message: String,
    accessibilityIdentifier: String? = nil,
    rollupDuplicates: Bool = false
  ) -> UUID {
    toast.presentSuccess(
      message,
      accessibilityIdentifier: accessibilityIdentifier,
      rollupDuplicates: rollupDuplicates
    )
  }

  @discardableResult
  public func presentFailureFeedback(
    _ message: String,
    accessibilityIdentifier: String? = nil,
    rollupDuplicates: Bool = false
  ) -> UUID {
    toast.presentFailure(
      message,
      accessibilityIdentifier: accessibilityIdentifier,
      rollupDuplicates: rollupDuplicates
    )
  }

  public func dismissFeedback(id: UUID) {
    toast.dismiss(id: id)
  }
}
