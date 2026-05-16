import Foundation

extension HarnessMonitorStore {
  /// Guarantees the cache has at least one detail row for a session that the user is about to
  /// view in a SessionWindow. Idempotent: returns immediately when the cache already has data
  /// for the session, so it is cheap to call on every `task(id:)` activation. When the cache
  /// misses, it can hydrate even sessions that are not yet present in the live session index
  /// (for example a brand-new session window opened before the session list refresh catches up).
  /// It persists the fetched summary immediately, then follows up with detail + the most recent
  /// timeline window so the next supervisor tick can include the session in its snapshot with
  /// live agents, tasks, and timeline density.
  @MainActor
  public func ensureSessionDetailHydratedForOpenWindow(sessionID: String) async {
    guard cacheService != nil, persistenceError == nil else { return }
    if await loadCachedSessionDetail(sessionID: sessionID) != nil {
      return
    }
    guard let client else {
      return
    }
    do {
      let detailScope = activeTransport == .webSocket ? "core" : nil
      let detail = try await client.sessionDetail(id: sessionID, scope: detailScope)
      try Task.checkCancellation()
      let didApplySummary = sessionIndex.applySessionSummary(detail.session)
      if didApplySummary {
        let project = sessionIndex.projects.first { $0.projectId == detail.session.projectId }
        await cacheSessionSummary(detail.session, project: project)
      }
      let timelineResponse = try await client.timelineWindow(
        sessionID: sessionID,
        request: .latest(limit: Self.initialSelectedTimelineWindowLimit)
      )
      try Task.checkCancellation()
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
    } catch is CancellationError {
      return
    } catch {
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.open_window_hydration_failed session=\(sessionID) "
          + "error=\(String(describing: error))"
      )
    }
  }
}
