import Foundation

extension HarnessMonitorStore {
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
    sessionSnapshotHydrationTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      defer { self.sessionSnapshotHydrationTask = nil }

      let prioritySessions: [SessionSummary]
      if let cacheService = self.cacheService {
        var recentIDs = Set(await cacheService.recentlyViewedSessionIDs(limit: 10))
        if let selected = self.selectedSessionID {
          recentIDs.insert(selected)
        }
        prioritySessions = sessions.filter { recentIDs.contains($0.sessionId) }
      } else {
        prioritySessions = []
      }

      let hydrationQueue = await self.persistedSnapshotHydrationQueue(for: prioritySessions)
      guard !hydrationQueue.isEmpty else { return }

      var batch: [(detail: SessionDetail, timeline: [TimelineEntry])] = []
      batch.reserveCapacity(hydrationQueue.count)

      for summary in hydrationQueue {
        guard !Task.isCancelled, self.connectionState == .online else {
          break
        }

        do {
          let measuredDetail = try await Self.measureOperation {
            try await client.sessionDetail(id: summary.sessionId)
          }
          let measuredTimeline = try await Self.measureOperation {
            try await client.timeline(sessionID: summary.sessionId)
          }
          self.recordRequestSuccess()
          self.recordRequestSuccess()

          batch.append((detail: measuredDetail.value, timeline: measuredTimeline.value))

          let isSelected = self.selectedSessionID == summary.sessionId
          let needsUpdate = self.selectedSession == nil || self.isShowingCachedData
          if isSelected && needsUpdate {
            self.applySelectedSessionSnapshot(
              sessionID: summary.sessionId,
              detail: measuredDetail.value,
              timeline: measuredTimeline.value,
              showingCachedData: false
            )
          }
        } catch {
          guard !Task.isCancelled else {
            return
          }
          self.appendConnectionEvent(
            kind: .error,
            detail: "Persisted snapshot refresh failed for \(summary.sessionId)"
          )
        }
      }

      if !batch.isEmpty {
        await self.cacheSessionDetails(batch, markViewed: false)
      }
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
