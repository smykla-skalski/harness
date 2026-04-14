import Foundation

extension HarnessMonitorStore {
  func restorePersistedSessionStateWhileConnecting() async {
    guard connectionState == .connecting else { return }

    await refreshPersistedSessionMetadata()
    guard connectionState == .connecting else { return }

    if sessions.isEmpty, let cached = await loadCachedSessionList() {
      guard connectionState == .connecting else { return }
      withUISyncBatch {
        sessionIndex.replaceSnapshot(
          projects: cached.projects,
          sessions: cached.sessions
        )
      }
    }

    guard connectionState == .connecting else { return }

    withUISyncBatch {
      isShowingCachedData = persistedSessionCount > 0 || !sessions.isEmpty
    }

    if let selectedSessionID,
      selectedSession?.session.sessionId != selectedSessionID
    {
      await restorePersistedSessionSelectionWhileConnecting(sessionID: selectedSessionID)
    } else {
      withUISyncBatch {
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
      applySelectedSessionSnapshot(
        sessionID: sessionID,
        detail: cached.detail,
        timeline: cached.timeline,
        showingCachedData: true
      )
    } else if let summary = sessionIndex.sessionSummary(for: sessionID) {
      guard connectionState == .connecting else { return }
      applySelectedSessionSnapshot(
        sessionID: sessionID,
        detail: summaryOnlySessionDetail(for: summary),
        timeline: [],
        showingCachedData: true
      )
    } else {
      guard connectionState == .connecting else { return }
      withUISyncBatch {
        isShowingCachedData = persistedSessionCount > 0 || !sessions.isEmpty
      }
    }

    withUISyncBatch {
      activeSessionLoadRequest = 0
      isSelectionLoading = false
    }
  }

  func applyCachedSessionIfAvailable(sessionID: String) async {
    guard selectedSessionID == sessionID, selectedSession == nil else { return }

    if let cached = await loadCachedSessionDetail(sessionID: sessionID) {
      guard selectedSessionID == sessionID else { return }
      withUISyncBatch {
        selectedSession = cached.detail
        timeline = cached.timeline
        isSelectionLoading = false
      }
    }
  }

  func restorePersistedSessionSelection(sessionID: String) async {
    if let cached = await loadCachedSessionDetail(sessionID: sessionID) {
      applySelectedSessionSnapshot(
        sessionID: sessionID,
        detail: cached.detail,
        timeline: cached.timeline,
        showingCachedData: true
      )
    } else if let summary = sessionIndex.sessionSummary(for: sessionID) {
      applySelectedSessionSnapshot(
        sessionID: sessionID,
        detail: summaryOnlySessionDetail(for: summary),
        timeline: [],
        showingCachedData: true
      )
    } else {
      withUISyncBatch {
        isShowingCachedData = persistedSessionCount > 0 || !sessions.isEmpty
      }
    }

    withUISyncBatch {
      activeSessionLoadRequest = 0
      isSelectionLoading = false
    }
  }

  func restorePersistedSessionState() async {
    await refreshPersistedSessionMetadata()

    if sessions.isEmpty, let cached = await loadCachedSessionList() {
      withUISyncBatch {
        sessionIndex.replaceSnapshot(
          projects: cached.projects,
          sessions: cached.sessions
        )
      }
    }

    if case .offline = connectionState {
      withUISyncBatch {
        isShowingCachedData = persistedSessionCount > 0 || !sessions.isEmpty
      }
    }

    if let selectedSessionID, selectedSession?.session.sessionId != selectedSessionID {
      await restorePersistedSessionSelection(sessionID: selectedSessionID)
    } else {
      withUISyncBatch {
        activeSessionLoadRequest = 0
        isSelectionLoading = false
      }
    }

    synchronizeActionActor()
  }

  func schedulePersistedSnapshotHydration(
    using client: any HarnessMonitorClientProtocol,
    sessions: [SessionSummary]
  ) {
    guard cacheService != nil, persistenceError == nil else {
      sessionSnapshotHydrationTask?.cancel()
      sessionSnapshotHydrationTask = nil
      return
    }

    sessionSnapshotHydrationTask?.cancel()
    sessionSnapshotHydrationTask = Task(priority: .utility) { @MainActor [weak self] in
      guard let self else { return }
      defer { self.sessionSnapshotHydrationTask = nil }
      await self.runPersistedSnapshotHydration(using: client, sessions: sessions)
    }
  }

  private func runPersistedSnapshotHydration(
    using client: any HarnessMonitorClientProtocol,
    sessions: [SessionSummary]
  ) async {
    await Task.yield()
    while let sessionLoadTask = sessionLoadTask {
      await sessionLoadTask.value
      guard !Task.isCancelled, connectionState == .online else { return }
    }

    let prioritySessions = await resolveHydrationPrioritySessions(from: sessions)
    let hydrationQueue = await persistedSnapshotHydrationQueue(for: prioritySessions)
    guard !hydrationQueue.isEmpty else { return }

    var batch: [(detail: SessionDetail, timeline: [TimelineEntry])] = []
    batch.reserveCapacity(hydrationQueue.count)

    for summary in hydrationQueue {
      guard !Task.isCancelled, connectionState == .online else { break }
      await fetchAndApplyHydrationSnapshot(
        using: client,
        summary: summary,
        batch: &batch
      )
    }

    if !batch.isEmpty {
      await cacheSessionDetails(batch, markViewed: false)
    }
  }

  private func resolveHydrationPrioritySessions(
    from sessions: [SessionSummary]
  ) async -> [SessionSummary] {
    guard let cacheService else { return [] }
    let recentIDs = Set(await cacheService.recentlyViewedSessionIDs(limit: 10))
    let selectedSessionID = selectedSessionID
    let selectedSessionNeedsHydration =
      selectedSessionID != nil && (selectedSession == nil || isShowingCachedData)
    return sessions.filter {
      if $0.sessionId == selectedSessionID {
        return selectedSessionNeedsHydration
      }
      return recentIDs.contains($0.sessionId)
    }
  }

  private func fetchAndApplyHydrationSnapshot(
    using client: any HarnessMonitorClientProtocol,
    summary: SessionSummary,
    batch: inout [(detail: SessionDetail, timeline: [TimelineEntry])]
  ) async {
    do {
      let detailScope = activeTransport == .webSocket ? "core" : nil
      let timelineScope: TimelineScope = .summary
      let measuredDetail = try await Self.measureOperation {
        try await client.sessionDetail(id: summary.sessionId, scope: detailScope)
      }
      recordRequestSuccess()
      let isSelected = selectedSessionID == summary.sessionId
      let needsUpdate = selectedSession == nil || isShowingCachedData
      if isSelected && needsUpdate {
        applySelectedSessionSnapshot(
          sessionID: summary.sessionId,
          detail: measuredDetail.value,
          timeline: timeline,
          showingCachedData: false,
          cancelPendingTimelineRefresh: false
        )
      }

      let measuredTimeline = try await Self.measureOperation {
        try await client.timeline(
          sessionID: summary.sessionId,
          scope: timelineScope
        ) { [weak self] batch, batchIndex, _ in
          await MainActor.run {
            guard isSelected && needsUpdate else { return }
            self?.applySelectedTimelineBatch(
              batch,
              index: batchIndex,
              sessionID: summary.sessionId
            )
          }
        }
      }
      recordRequestSuccess()

      batch.append((detail: measuredDetail.value, timeline: measuredTimeline.value))

      if isSelected && needsUpdate {
        applySelectedSessionSnapshot(
          sessionID: summary.sessionId,
          detail: measuredDetail.value,
          timeline: measuredTimeline.value,
          showingCachedData: false,
          cancelPendingTimelineRefresh: false
        )
      }
    } catch {
      guard !Task.isCancelled else { return }
      appendConnectionEvent(
        kind: .error,
        detail: "Persisted snapshot refresh failed for \(summary.sessionId)"
      )
    }
  }

  private func summaryOnlySessionDetail(for summary: SessionSummary) -> SessionDetail {
    SessionDetail(
      session: summary,
      agents: [],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )
  }
}
