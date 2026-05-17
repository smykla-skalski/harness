import Foundation

extension HarnessMonitorStore {
  func fallbackTimelineWindow(for timeline: [TimelineEntry]) -> TimelineWindowResponse? {
    Self.fallbackTimelineWindow(for: timeline)
  }

  func selectedTimelineRequestLimit(
    loadedTimeline: [TimelineEntry],
    timelineWindow: TimelineWindowResponse?
  ) -> Int {
    max(1, selectedTimelinePreferredWindowLimit ?? Self.initialSelectedTimelineWindowLimit)
  }

  public func updateSelectedTimelinePreferredWindowLimit(_ limit: Int?) {
    let normalizedLimit = limit.map { max(1, $0) }
    guard selectedTimelinePreferredWindowLimit != normalizedLimit else {
      return
    }
    selectedTimelinePreferredWindowLimit = normalizedLimit
  }

  /// Resolve the timeline window after a streaming push delivers a new timeline
  /// snapshot. Preserves `hasOlder` / `totalCount` / `windowStart` from the
  /// existing in-memory window so paged loads (`appendSelectedTimelineOlderChunk`)
  /// keep working after live updates. Falls back to synthetic metadata only when
  /// no prior window existed.
  func mergedTimelineWindowAfterPush(
    payloadTimeline: [TimelineEntry]?
  ) -> TimelineWindowResponse? {
    guard let payloadTimeline else {
      return timelineWindow
    }
    return normalizedTimelineWindow(timelineWindow, loadedTimeline: payloadTimeline)
      ?? TimelineWindowResponse.fallbackMetadata(for: payloadTimeline)
  }

  func normalizedTimelineWindow(
    _ timelineWindow: TimelineWindowResponse?,
    loadedTimeline: [TimelineEntry]
  ) -> TimelineWindowResponse? {
    Self.normalizedTimelineWindow(timelineWindow, loadedTimeline: loadedTimeline)
  }

  nonisolated static func fallbackTimelineWindow(
    for timeline: [TimelineEntry]
  ) -> TimelineWindowResponse? {
    guard !timeline.isEmpty else {
      return nil
    }
    return TimelineWindowResponse.fallbackMetadata(for: timeline)
  }

  nonisolated static func normalizedTimelineWindow(
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
