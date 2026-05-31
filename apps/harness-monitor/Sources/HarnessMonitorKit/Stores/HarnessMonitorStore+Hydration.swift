import Foundation

extension HarnessMonitorStore {
  func restoreSelectedAcpTranscriptFromCache(
    _ transcript: [TimelineEntry]?,
    source: HarnessMonitorSessionWindowTranscriptSource?
  ) {
    suppressSelectedAcpTranscriptCacheWrite = true
    defer { suppressSelectedAcpTranscriptCacheWrite = false }
    selectedAcpTranscriptSource = source
    selectedAcpTranscriptHistoryEntries = transcript ?? []
    selectedAcpTranscriptLiveEntries = []
  }

  func applyCachedSelectedSessionSnapshot(
    sessionID: String,
    cached: SessionCacheService.CachedSessionSnapshot,
    showingCachedData: Bool,
    cancelPendingTimelineRefresh: Bool = true
  ) {
    restoreSelectedAcpTranscriptFromCache(
      cached.transcript,
      source: cached.transcriptSource
    )
    applySelectedSessionSnapshot(
      sessionID: sessionID,
      detail: cached.detail,
      timeline: cached.timeline,
      timelineWindow: cached.timelineWindow,
      showingCachedData: showingCachedData,
      cancelPendingTimelineRefresh: cancelPendingTimelineRefresh
    )
  }

  func restorePersistedSessionStateWhileConnecting() async {
    guard connectionState == .connecting else { return }

    // Restore global task-board content first so external items are visible on
    // launch even if the daemon reconnects before session-list hydration ends.
    await restorePersistedTaskBoardState()
    await restorePersistedPolicyPipelineState()

    await refreshPersistedSessionMetadata()
    guard connectionState == .connecting else { return }

    if sessions.isEmpty, let cached = await loadCachedSessionList() {
      let generation = beginSessionIndexSnapshotApply()
      guard
        let filteredCached = await preparedSessionIndexSnapshot(
          projects: cached.projects,
          sessions: cached.sessions,
          generation: generation
        )
      else {
        return
      }
      guard connectionState == .connecting else { return }
      replaceCachedSessionIndexSnapshot(filteredCached, updateCachedCatalogFlag: false)
    }

    guard connectionState == .connecting else { return }

    withUISyncBatch {
      isShowingCachedCatalog = persistedSessionCount > 0 || !sessions.isEmpty
    }

    if let selectedSessionID,
      selectedSession?.session.sessionId != selectedSessionID
    {
      await restorePersistedSessionSelectionWhileConnecting(sessionID: selectedSessionID)
    } else {
      withUISyncBatch {
        isShowingCachedData =
          selectedSessionID != nil
          && selectedSession?.session.sessionId == selectedSessionID
        activeSessionLoadRequest = 0
        isSelectionLoading = false
      }
    }

    synchronizeActionActor()
  }

  private func restorePersistedSessionSelectionWhileConnecting(
    sessionID: String
  ) async {
    guard connectionState == .connecting else { return }

    if let cached = await loadCachedSessionDetail(sessionID: sessionID) {
      guard connectionState == .connecting, selectedSessionID == sessionID else {
        return
      }
      applyCachedSelectedSessionSnapshot(
        sessionID: sessionID,
        cached: cached,
        showingCachedData: true
      )
    } else if let summary = sessionIndex.sessionSummary(for: sessionID) {
      guard connectionState == .connecting else { return }
      applySelectedSessionSnapshot(
        sessionID: sessionID,
        detail: summaryOnlySessionDetail(for: summary),
        timeline: [],
        timelineWindow: nil,
        showingCachedData: true
      )
    } else {
      guard connectionState == .connecting else { return }
      withUISyncBatch {
        isShowingCachedCatalog = persistedSessionCount > 0 || !sessions.isEmpty
      }
    }

    withUISyncBatch {
      activeSessionLoadRequest = 0
      isSelectionLoading = false
    }
  }

  func applyCachedSessionIfAvailable(sessionID: String) async {
    guard selectedSessionID == sessionID else { return }

    if let cached = await loadCachedSessionDetail(sessionID: sessionID) {
      guard selectedSessionID == sessionID else { return }
      let shouldPromoteCachedSnapshot =
        selectedSession?.session.sessionId != sessionID
        || timeline.isEmpty
        || isShowingCachedData
      guard shouldPromoteCachedSnapshot else { return }
      // Cache is only ever applied here as scaffold for an in-flight live
      // fetch. The persistence banner must stay hidden so session switches do
      // not flash a stale-data warning between cache paint and live arrival;
      // the banner is only raised by the dedicated offline fallback paths.
      applyCachedSelectedSessionSnapshot(
        sessionID: sessionID,
        cached: cached,
        showingCachedData: false,
        cancelPendingTimelineRefresh: false
      )
      withUISyncBatch {
        isSelectionLoading = false
      }
    }
  }

  func restorePersistedTaskBoardState() async {
    let shouldRestoreItems = globalTaskBoardItems.isEmpty
    let shouldRestoreStatus = globalTaskBoardOrchestratorStatus == nil
    guard shouldRestoreItems || shouldRestoreStatus else {
      return
    }
    guard let cached = await loadCachedTaskBoardSnapshot() else {
      return
    }

    withUISyncBatch {
      if shouldRestoreItems {
        globalTaskBoardItems = cached.items
      }
      if shouldRestoreStatus {
        globalTaskBoardOrchestratorStatus = cached.orchestratorStatus
      }
    }
  }

  func restorePersistedPolicyPipelineState() async {
    guard globalTaskBoardPolicyPipeline == nil else { return }
    guard let cached = await loadCachedPolicyDocument() else { return }
    withUISyncBatch {
      globalTaskBoardPolicyPipeline = cached
    }
  }

  func restorePersistedSessionSelection(sessionID: String) async {
    if let cached = await loadCachedSessionDetail(sessionID: sessionID) {
      applyCachedSelectedSessionSnapshot(
        sessionID: sessionID,
        cached: cached,
        showingCachedData: true
      )
    } else if let summary = sessionIndex.sessionSummary(for: sessionID) {
      applySelectedSessionSnapshot(
        sessionID: sessionID,
        detail: summaryOnlySessionDetail(for: summary),
        timeline: [],
        timelineWindow: nil,
        showingCachedData: true
      )
    } else {
      withUISyncBatch {
        isShowingCachedCatalog = persistedSessionCount > 0 || !sessions.isEmpty
      }
    }

    withUISyncBatch {
      activeSessionLoadRequest = 0
      isSelectionLoading = false
    }
  }

  func restorePersistedSessionState() async {
    await restorePersistedTaskBoardState()
    await refreshPersistedSessionMetadata()

    if sessions.isEmpty, let cached = await loadCachedSessionList() {
      let generation = beginSessionIndexSnapshotApply()
      guard
        let filteredCached = await preparedSessionIndexSnapshot(
          projects: cached.projects,
          sessions: cached.sessions,
          generation: generation
        )
      else {
        return
      }
      replaceCachedSessionIndexSnapshot(filteredCached, updateCachedCatalogFlag: false)
    }

    if case .offline = connectionState {
      withUISyncBatch {
        isShowingCachedCatalog = persistedSessionCount > 0 || !sessions.isEmpty
      }
    }

    if let selectedSessionID, selectedSession?.session.sessionId != selectedSessionID {
      await restorePersistedSessionSelection(sessionID: selectedSessionID)
    } else {
      withUISyncBatch {
        isShowingCachedData =
          selectedSessionID != nil
          && selectedSession?.session.sessionId == selectedSessionID
        activeSessionLoadRequest = 0
        isSelectionLoading = false
      }
    }

    synchronizeActionActor()
  }
}
