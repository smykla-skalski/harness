import Foundation

extension HarnessMonitorStore {
  func handleSessionLoadError(
    _ error: any Error,
    requestID: UInt64,
    sessionID: String
  ) async {
    guard isCurrentSessionLoad(requestID, sessionID: sessionID) else { return }

    withUISyncBatch {
      isExtensionsLoading = false
      isTimelineLoading = false
    }
    cancelTimelineLoadingGate()

    if shouldTreatMissingSessionLoadAsLocalRemoval(error) {
      await pruneLocallyRemovedSessionAfterLoadError(error, sessionID: sessionID)
      return
    }

    logSessionLoadFallback(error, sessionID: sessionID)
    await applySessionLoadFallback(sessionID: sessionID)
  }

  private func pruneLocallyRemovedSessionAfterLoadError(
    _ error: any Error,
    sessionID: String
  ) async {
    let err = error.localizedDescription
    HarnessMonitorLogger.store.info(
      """
      session detail hydration pruned stale session \
      \(sessionID, privacy: .public): \(err, privacy: .public)
      """
    )
    let localSnapshot = await applyLocalSessionRemoval(sessionID: sessionID)
    await pruneRemovedSessionFromCache(
      sessions: localSnapshot.sessions,
      projects: localSnapshot.projects
    )
  }

  private func logSessionLoadFallback(_ error: any Error, sessionID: String) {
    // Background hydration: log silently. The fallback below is the
    // user-visible recovery; no toast is needed for an automatic load.
    let err = error.localizedDescription
    HarnessMonitorLogger.store.warning(
      "session detail hydration failed for \(sessionID, privacy: .public): \(err, privacy: .public)"
    )
  }

  private func applySessionLoadFallback(sessionID: String) async {
    guard selectedSession?.session.sessionId != sessionID else { return }

    if let cached = await loadCachedSessionDetail(sessionID: sessionID) {
      applyCachedSelectedSessionSnapshot(
        sessionID: sessionID,
        cached: cached,
        showingCachedData: true
      )
    } else if let summary = sessionIndex.sessionSummary(for: sessionID) {
      applySelectedSessionSnapshot(
        sessionID: sessionID,
        detail: SessionDetail(
          session: summary,
          agents: [],
          tasks: [],
          signals: [],
          observer: nil,
          agentActivity: []
        ),
        timeline: [],
        timelineWindow: nil,
        showingCachedData: true
      )
    } else {
      withUISyncBatch {
        isShowingCachedCatalog = persistedSessionCount > 0 || !sessions.isEmpty
      }
    }
  }

  private func shouldTreatMissingSessionLoadAsLocalRemoval(
    _ error: any Error
  ) -> Bool {
    guard let apiError = error as? HarnessMonitorAPIError,
      case .server(let code, _) = apiError,
      (400...404).contains(code)
    else {
      return false
    }

    let message = (apiError.serverMessage ?? error.localizedDescription).lowercased()
    if apiError.serverSemanticCode?.lowercased() == "session_not_active" {
      return message.contains("not found")
    }

    return message.contains("session not active")
      && message.contains("session")
      && message.contains("not found")
  }
}
