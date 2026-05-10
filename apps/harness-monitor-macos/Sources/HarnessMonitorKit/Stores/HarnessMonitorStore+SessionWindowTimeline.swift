import Foundation

extension HarnessMonitorStore {
  public func loadSessionWindowTimeline(
    sessionID: String,
    snapshot: HarnessMonitorSessionWindowSnapshot,
    request: TimelineWindowRequest,
    retainedLimit: Int? = nil
  ) async -> HarnessMonitorSessionWindowSnapshot? {
    guard connectionState == .online, let client else {
      return nil
    }

    do {
      let response = try await Self.measureOperation {
        try await client.timelineWindow(sessionID: sessionID, request: request)
      }
      recordRequestSuccess()
      let resolved = resolvedSessionWindowTimeline(
        snapshot: snapshot,
        response: response.value,
        request: request,
        retainedLimit: retainedLimit
      )
      let nextSnapshot = HarnessMonitorSessionWindowSnapshot(
        summary: snapshot.summary,
        detail: snapshot.detail,
        timeline: resolved.timeline,
        timelineWindow: resolved.timelineWindow,
        source: .live
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
    request: TimelineWindowRequest,
    retainedLimit: Int?
  ) -> (timeline: [TimelineEntry], timelineWindow: TimelineWindowResponse?) {
    if let rollingResolution = TimelineRollingWindowResolver.resolve(
      existingTimeline: snapshot.timeline,
      currentWindow: snapshot.timelineWindow,
      response: response,
      request: request,
      retainedLimit: retainedLimit
    )
    {
      return (rollingResolution.timeline, rollingResolution.timelineWindow)
    }

    let resolvedTimeline = response.entries ?? snapshot.timeline
    let resolvedTimelineWindow =
      normalizedTimelineWindow(response.metadataOnly, loadedTimeline: resolvedTimeline)
      ?? response.metadataOnly
    return (resolvedTimeline, resolvedTimelineWindow)
  }
}
