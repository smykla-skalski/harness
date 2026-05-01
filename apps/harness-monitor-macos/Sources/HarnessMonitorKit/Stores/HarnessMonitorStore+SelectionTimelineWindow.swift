import Foundation

extension HarnessMonitorStore {
  private static let selectedTimelineRetainedEntryLimit = 300

  public func loadSelectedTimelineWindow(request: TimelineWindowRequest) async {
    guard let sessionID = selectedSessionID, let selectedSession, connectionState == .online,
      let client
    else {
      return
    }

    let loadKey = SelectedTimelineWindowLoadKey(sessionID: sessionID, request: request)
    if let selectedTimelineWindowLoadTask, selectedTimelineWindowLoadKey == loadKey {
      await selectedTimelineWindowLoadTask.value
      return
    }

    cancelSelectedTimelinePageLoad()
    cancelSelectedTimelineWindowLoad()
    selectedTimelineWindowLoadSequence &+= 1
    let token = selectedTimelineWindowLoadSequence
    selectedTimelineWindowLoadKey = loadKey

    withUISyncBatch {
      isTimelineLoading = true
    }
    let task = Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      defer {
        self.finishSelectedTimelineWindowLoadIfCurrent(token, sessionID: sessionID)
      }

      do {
        let response = try await Self.measureOperation {
          try await client.timelineWindow(sessionID: sessionID, request: request)
        }
        self.recordRequestSuccess()
        guard !Task.isCancelled else {
          return
        }
        guard self.isCurrentSelectedTimelineWindowLoad(token, key: loadKey) else {
          return
        }
        self.applySelectedTimelineWindowResponse(
          response.value,
          request: request,
          selectedSession: selectedSession
        )
      } catch is CancellationError {
        return
      } catch {
        guard self.isCurrentSelectedTimelineWindowLoad(token, key: loadKey) else {
          return
        }
        let detail = error.localizedDescription
        HarnessMonitorLogger.store.warning(
          """
          timeline window load failed for \
          \(sessionID, privacy: .public): \(detail, privacy: .public)
          """
        )
      }
    }
    selectedTimelineWindowLoadTask = task
    await task.value
  }

  func cancelSelectedTimelineWindowLoad() {
    selectedTimelineWindowLoadTask?.cancel()
    selectedTimelineWindowLoadTask = nil
    selectedTimelineWindowLoadKey = nil
    selectedTimelineWindowLoadSequence &+= 1
  }

  func applySelectedTimelineWindowResponse(
    _ response: TimelineWindowResponse,
    request: TimelineWindowRequest,
    selectedSession: SessionDetail
  ) {
    let resolvedSnapshot = mergedSelectedTimelineSnapshot(
      response,
      request: request
    )

    withUISyncBatch {
      resetToolCallTimelineBurstState()
      timeline = resolvedSnapshot.timeline
      timelineWindow = resolvedSnapshot.timelineWindow
      isShowingCachedData = false
    }
    scheduleCacheWrite { service in
      await service.cacheSessionDetail(
        selectedSession,
        timeline: resolvedSnapshot.timeline,
        timelineWindow: resolvedSnapshot.timelineWindow
      )
    }
  }

  private func mergedSelectedTimelineSnapshot(
    _ response: TimelineWindowResponse,
    request: TimelineWindowRequest
  ) -> (timeline: [TimelineEntry], timelineWindow: TimelineWindowResponse) {
    let currentWindow = timelineWindow
    let currentRange = TimelineWindowRange(
      start: currentWindow?.windowStart ?? 0,
      end: currentWindow?.windowEnd ?? timeline.count
    )

    if request.before != nil {
      return boundedTimelineSnapshot(
        entries: mergeOlderTimelineEntries(response.entries ?? [], into: timeline),
        range: currentRange.union(with: response),
        response: response,
        trimBias: .older
      )
    }

    if request.after != nil {
      return boundedTimelineSnapshot(
        entries: mergeNewerTimelineEntries(response.entries ?? [], into: timeline),
        range: currentRange.union(with: response),
        response: response,
        trimBias: .newer
      )
    }

    return boundedTimelineSnapshot(
      entries: response.entries ?? timeline,
      range: TimelineWindowRange(start: response.windowStart, end: response.windowEnd),
      response: response,
      trimBias: .newer
    )
  }

  private func boundedTimelineSnapshot(
    entries: [TimelineEntry],
    range: TimelineWindowRange,
    response: TimelineWindowResponse,
    trimBias: TimelineTrimBias
  ) -> (timeline: [TimelineEntry], timelineWindow: TimelineWindowResponse) {
    let bounded = Self.trimTimelineEntries(
      entries,
      range: range,
      bias: trimBias,
      limit: Self.selectedTimelineRetainedEntryLimit
    )
    let timelineWindow = TimelineWindowResponse(
      revision: response.revision,
      totalCount: max(response.totalCount, bounded.entries.count),
      windowStart: bounded.range.start,
      windowEnd: bounded.range.end,
      hasOlder: response.hasOlder || bounded.range.end < response.totalCount,
      hasNewer: response.hasNewer || bounded.range.start > 0,
      oldestCursor: bounded.entries.last.map(\.timelineCursor),
      newestCursor: bounded.entries.first.map(\.timelineCursor),
      entries: nil,
      unchanged: response.unchanged
    )
    return (bounded.entries, timelineWindow)
  }

  private func mergeOlderTimelineEntries(
    _ olderEntries: [TimelineEntry],
    into existingEntries: [TimelineEntry]
  ) -> [TimelineEntry] {
    guard !olderEntries.isEmpty else {
      return existingEntries
    }
    var mergedEntries = existingEntries
    var existingKeys = Set(existingEntries.map(Self.timelineEntryKey))
    for entry in olderEntries where existingKeys.insert(Self.timelineEntryKey(entry)).inserted {
      mergedEntries.append(entry)
    }
    return mergedEntries
  }

  private func mergeNewerTimelineEntries(
    _ newerEntries: [TimelineEntry],
    into existingEntries: [TimelineEntry]
  ) -> [TimelineEntry] {
    guard !newerEntries.isEmpty else {
      return existingEntries
    }
    var mergedEntries = newerEntries
    var existingKeys = Set(newerEntries.map(Self.timelineEntryKey))
    for entry in existingEntries where existingKeys.insert(Self.timelineEntryKey(entry)).inserted {
      mergedEntries.append(entry)
    }
    return mergedEntries
  }

  private static func trimTimelineEntries(
    _ entries: [TimelineEntry],
    range: TimelineWindowRange,
    bias: TimelineTrimBias,
    limit: Int
  ) -> (entries: [TimelineEntry], range: TimelineWindowRange) {
    guard entries.count > limit, limit > 0 else {
      return (entries, range)
    }
    let overflow = entries.count - limit
    switch bias {
    case .older:
      return (
        Array(entries.dropFirst(overflow)),
        TimelineWindowRange(start: range.start + overflow, end: range.end)
      )
    case .newer:
      return (
        Array(entries.dropLast(overflow)),
        TimelineWindowRange(start: range.start, end: range.end - overflow)
      )
    }
  }

  private static func timelineEntryKey(_ entry: TimelineEntry) -> String {
    "\(entry.recordedAt)|\(entry.entryId)"
  }

  func isCurrentSelectedTimelineWindowLoad(
    _ token: UInt64,
    key: SelectedTimelineWindowLoadKey
  ) -> Bool {
    selectedTimelineWindowLoadSequence == token
      && selectedTimelineWindowLoadKey == key
      && selectedSessionID == key.sessionID
  }

  func finishSelectedTimelineWindowLoadIfCurrent(_ token: UInt64, sessionID: String) {
    guard selectedTimelineWindowLoadSequence == token else {
      return
    }
    selectedTimelineWindowLoadTask = nil
    selectedTimelineWindowLoadKey = nil
    if selectedSessionID == sessionID {
      isTimelineLoading = false
    }
  }
}

extension HarnessMonitorStore {
  struct SelectedTimelineWindowLoadKey: Equatable {
    let sessionID: String
    let request: TimelineWindowRequest
  }
}

private enum TimelineTrimBias {
  case older
  case newer
}

private struct TimelineWindowRange {
  let start: Int
  let end: Int

  func union(with response: TimelineWindowResponse) -> Self {
    Self(
      start: min(start, response.windowStart),
      end: max(end, response.windowEnd)
    )
  }
}
