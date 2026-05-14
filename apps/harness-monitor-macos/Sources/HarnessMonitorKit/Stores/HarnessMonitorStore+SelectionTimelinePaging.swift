import Foundation

extension HarnessMonitorStore {
  func refreshSelectedTimelineDelta(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String,
    loadedTimeline: [TimelineEntry],
    loadedWindow: TimelineWindowResponse
  ) async throws -> (timeline: [TimelineEntry], timelineWindow: TimelineWindowResponse) {
    let limit = selectedTimelineRequestLimit(
      loadedTimeline: loadedTimeline,
      timelineWindow: loadedWindow
    )
    guard
      let newestCursor = loadedWindow.newestCursor
        ?? loadedTimeline.first.map({
          TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
        })
    else {
      let latestWindow = try await fetchSelectedTimelineLatestWindow(
        using: client,
        sessionID: sessionID,
        limit: limit
      )
      let latestTimeline = latestWindow.entries ?? loadedTimeline
      let normalizedWindow =
        normalizedTimelineWindow(latestWindow.metadataOnly, loadedTimeline: latestTimeline)
        ?? latestWindow.metadataOnly
      return (latestTimeline, normalizedWindow)
    }

    let deltaWindow = try await Self.measureOperation {
      try await client.timelineWindow(
        sessionID: sessionID,
        request: TimelineWindowRequest(
          scope: .summary,
          limit: limit,
          after: newestCursor
        )
      )
    }
    recordRequestSuccess()

    let deltaResponse = deltaWindow.value
    if let deltaEntries = deltaResponse.entries, deltaEntries.isEmpty == false {
      guard canSafelyMergeNewerTimelineEntries(deltaResponse) else {
        let latestWindow = try await fetchSelectedTimelineLatestWindow(
          using: client,
          sessionID: sessionID,
          limit: limit
        )
        let latestTimeline = latestWindow.entries ?? loadedTimeline
        let normalizedWindow =
          normalizedTimelineWindow(latestWindow.metadataOnly, loadedTimeline: latestTimeline)
          ?? latestWindow.metadataOnly
        return (latestTimeline, normalizedWindow)
      }

      let merged = TimelineRollingWindowResolver.prependingNewer(
        existingTimeline: loadedTimeline,
        currentWindow: loadedWindow,
        response: deltaResponse,
        newerEntries: deltaEntries,
        retainedLimit: limit
      )
      return (merged.timeline, merged.timelineWindow)
    }

    if deltaResponse.unchanged || deltaResponse.revision == loadedWindow.revision {
      let normalizedWindow =
        normalizedTimelineWindow(deltaResponse.metadataOnly, loadedTimeline: loadedTimeline)
        ?? deltaResponse.metadataOnly
      return (loadedTimeline, normalizedWindow)
    }

    let latestWindow = try await fetchSelectedTimelineLatestWindow(
      using: client,
      sessionID: sessionID,
      limit: limit
    )
    let latestTimeline = latestWindow.entries ?? loadedTimeline
    let normalizedWindow =
      normalizedTimelineWindow(latestWindow.metadataOnly, loadedTimeline: latestTimeline)
      ?? latestWindow.metadataOnly
    return (latestTimeline, normalizedWindow)
  }

  private func fetchSelectedTimelineLatestWindow(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String,
    limit: Int
  ) async throws -> TimelineWindowResponse {
    let latestWindow = try await Self.measureOperation {
      try await client.timelineWindow(
        sessionID: sessionID,
        request: .latest(limit: limit)
      )
    }
    recordRequestSuccess()
    return latestWindow.value
  }

  func applySelectedTimelinePageResponse(
    _ response: TimelineWindowResponse,
    currentRevision: Int64?,
    retainedLimit: Int? = nil,
    selectedSession: SessionDetail
  ) {
    let resolved = resolvedSelectedTimelinePage(
      response,
      currentRevision: currentRevision,
      retainedLimit: retainedLimit
    )
    let resolvedTimeline = resolved.timeline
    let resolvedTimelineWindow = resolved.timelineWindow

    withUISyncBatch {
      replaceSelectedTimelineSnapshot(
        resolvedTimeline,
        timelineWindow: resolvedTimelineWindow,
        clearBurstState: true
      )
      isShowingCachedData = false
    }
    scheduleSelectedSessionCacheWrite(
      selectedSession,
      timeline: resolvedTimeline,
      timelineWindow: resolvedTimelineWindow
    )
  }

  func fetchSelectedTimelinePrefix(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String,
    targetEnd: Int,
    missingCount: Int,
    retainedLimit: Int? = nil,
    currentRevision: Int64?
  ) async throws -> TimelineWindowResponse {
    if let oldestCursor = timelineWindow?.oldestCursor
      ?? timeline.last.map({
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      })
    {
      let olderPrefix = try await Self.measureOperation {
        try await client.timelineWindow(
          sessionID: sessionID,
          request: TimelineWindowRequest(
            scope: .summary,
            limit: missingCount,
            before: oldestCursor
          )
        )
      }
      recordRequestSuccess()

      if let currentRevision, olderPrefix.value.revision != currentRevision {
        let refreshedPrefix = try await Self.measureOperation {
          try await client.timelineWindow(
            sessionID: sessionID,
            request: .latest(limit: retainedLimit ?? targetEnd)
          )
        }
        recordRequestSuccess()
        return refreshedPrefix.value
      }

      return olderPrefix.value
    }

    let refreshedPrefix = try await Self.measureOperation {
      try await client.timelineWindow(
        sessionID: sessionID,
        request: .latest(limit: targetEnd)
      )
    }
    recordRequestSuccess()
    return refreshedPrefix.value
  }

  fileprivate func canSafelyMergeNewerTimelineEntries(
    _ response: TimelineWindowResponse
  ) -> Bool {
    response.windowStart == 0 && response.hasNewer == false
  }
}

extension HarnessMonitorStore {
  struct SelectedTimelinePageLoadKey: Equatable {
    let sessionID: String
    let targetEnd: Int
    let pageSize: Int
    let retainedLimit: Int?
    let revision: Int64?
  }
}
