import Foundation

extension HarnessMonitorStore {
  public func loadSessionWindowTimeline(
    sessionID: String,
    snapshot: HarnessMonitorSessionWindowSnapshot,
    request: TimelineWindowRequest
  ) async -> HarnessMonitorSessionWindowSnapshot? {
    guard connectionState == .online, let client else {
      HarnessMonitorTimelineTrace.info(
        """
        store.session_window_timeline_skip reason=unavailable \
        session=\(sessionID) request=\(HarnessMonitorTimelineTrace.requestSummary(request)) \
        state=\(String(describing: connectionState)) client=\(client != nil)
        """
      )
      return nil
    }

    HarnessMonitorTimelineTrace.info(
      """
      store.session_window_timeline_start session=\(sessionID) \
      request=\(HarnessMonitorTimelineTrace.requestSummary(request)) \
      loaded=\(snapshot.timeline.count) \
      current=\(HarnessMonitorTimelineTrace.windowSummary(snapshot.timelineWindow))
      """
    )

    do {
      let response = try await Self.measureOperation {
        try await client.timelineWindow(sessionID: sessionID, request: request)
      }
      recordRequestSuccess()
      let resolved = resolvedSessionWindowTimeline(
        snapshot: snapshot,
        response: response.value,
        request: request
      )
      let nextSnapshot = HarnessMonitorSessionWindowSnapshot(
        summary: snapshot.summary,
        detail: snapshot.detail,
        timeline: resolved.timeline,
        timelineWindow: resolved.timelineWindow,
        source: .live
      )
      HarnessMonitorTimelineTrace.info(
        """
        store.session_window_timeline_apply session=\(sessionID) \
        response=\(HarnessMonitorTimelineTrace.windowSummary(response.value)) \
        oldLoaded=\(snapshot.timeline.count) newLoaded=\(resolved.timeline.count) \
        resolved=\(HarnessMonitorTimelineTrace.windowSummary(resolved.timelineWindow))
        """
      )
      if let detail = snapshot.detail {
        scheduleCacheWrite { service in
          await service.cacheSessionDetail(
            detail,
            timeline: resolved.timeline,
            timelineWindow: resolved.timelineWindow
          )
        }
      }
      return nextSnapshot
    } catch is CancellationError {
      HarnessMonitorTimelineTrace.info(
        "store.session_window_timeline_cancelled session=\(sessionID)"
      )
      return nil
    } catch {
      let detail = error.localizedDescription
      HarnessMonitorLogger.store.warning(
        """
        session window timeline load failed for \
        \(sessionID, privacy: .public): \(detail, privacy: .public)
        """
      )
      return nil
    }
  }

  private func resolvedSessionWindowTimeline(
    snapshot: HarnessMonitorSessionWindowSnapshot,
    response: TimelineWindowResponse,
    request: TimelineWindowRequest
  ) -> (timeline: [TimelineEntry], timelineWindow: TimelineWindowResponse?) {
    if request.before != nil,
      response.windowStart != 0,
      response.revision == snapshot.timelineWindow?.revision,
      let olderEntries = response.entries
    {
      return resolvedSessionWindowOlderTimeline(
        snapshot: snapshot,
        response: response,
        olderEntries: olderEntries
      )
    }

    let resolvedTimeline = response.entries ?? snapshot.timeline
    let resolvedTimelineWindow =
      normalizedTimelineWindow(response.metadataOnly, loadedTimeline: resolvedTimeline)
      ?? response.metadataOnly
    return (resolvedTimeline, resolvedTimelineWindow)
  }

  private func resolvedSessionWindowOlderTimeline(
    snapshot: HarnessMonitorSessionWindowSnapshot,
    response: TimelineWindowResponse,
    olderEntries: [TimelineEntry]
  ) -> (timeline: [TimelineEntry], timelineWindow: TimelineWindowResponse?) {
    let resolvedTimeline = mergedSessionWindowTimelinePrefix(
      snapshot.timeline,
      olderEntries: olderEntries
    )
    let currentWindowStart = snapshot.timelineWindow?.windowStart ?? 0
    let currentHasNewer = snapshot.timelineWindow?.hasNewer ?? (currentWindowStart > 0)
    let resolvedTimelineWindow = TimelineWindowResponse(
      revision: response.revision,
      totalCount: max(response.totalCount, currentWindowStart + resolvedTimeline.count),
      windowStart: currentWindowStart,
      windowEnd: currentWindowStart + resolvedTimeline.count,
      hasOlder: response.hasOlder,
      hasNewer: currentHasNewer,
      oldestCursor: resolvedTimeline.last.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      },
      newestCursor: resolvedTimeline.first.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      },
      entries: nil,
      unchanged: response.unchanged
    )
    return (resolvedTimeline, resolvedTimelineWindow)
  }

  private func mergedSessionWindowTimelinePrefix(
    _ existingEntries: [TimelineEntry],
    olderEntries: [TimelineEntry]
  ) -> [TimelineEntry] {
    guard olderEntries.isEmpty == false else {
      return existingEntries
    }

    var mergedEntries = existingEntries
    var existingKeys = Set(existingEntries.map(SessionWindowTimelineEntryKey.init(entry:)))
    for entry in olderEntries
    where existingKeys.insert(SessionWindowTimelineEntryKey(entry: entry)).inserted {
      mergedEntries.append(entry)
    }
    return mergedEntries
  }
}

private struct SessionWindowTimelineEntryKey: Hashable {
  let recordedAt: String
  let entryID: String

  init(entry: TimelineEntry) {
    recordedAt = entry.recordedAt
    entryID = entry.entryId
  }
}
