import Foundation

extension HarnessMonitorStore {
  /// Guarantees the cache has at least one detail row for a session that the user is about to
  /// view in a SessionWindow. Idempotent: returns immediately when the cache already has data
  /// for the session, so it is cheap to call on every `task(id:)` activation. When the cache
  /// misses, it fetches detail + the most recent timeline window from the daemon and writes
  /// both into the cache before returning so the next supervisor tick can include the session
  /// in its snapshot with live agents, tasks, and timeline density.
  @MainActor
  public func ensureSessionDetailHydratedForOpenWindow(sessionID: String) async {
    guard cacheService != nil, persistenceError == nil else { return }
    if await loadCachedSessionDetail(sessionID: sessionID) != nil {
      return
    }
    guard let client, sessionIndex.sessionSummary(for: sessionID) != nil else {
      return
    }
    do {
      let detailScope = activeTransport == .webSocket ? "core" : nil
      let detail = try await client.sessionDetail(id: sessionID, scope: detailScope)
      let timelineResponse = try await client.timelineWindow(
        sessionID: sessionID,
        request: .latest(limit: Self.initialSelectedTimelineWindowLimit)
      )
      let timeline = timelineResponse.entries ?? []
      let timelineWindow = timelineResponse.metadataOnly
      await cacheSessionDetails(
        [
          SessionCacheService.CachedSessionSnapshot(
            detail: detail,
            timeline: timeline,
            timelineWindow: timelineWindow
          )
        ],
        markViewed: false
      )
    } catch {
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.open_window_hydration_failed session=\(sessionID) "
          + "error=\(String(describing: error))"
      )
    }
  }
}
