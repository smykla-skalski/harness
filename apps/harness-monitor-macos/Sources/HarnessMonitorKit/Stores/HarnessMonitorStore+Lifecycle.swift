import Foundation

extension HarnessMonitorStore {
  static let initialSelectedTimelineWindowLimit = 10

  func loadSession(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String,
    requestID: UInt64
  ) async {
    defer {
      completeSessionLoad(requestID)
    }

    // Direct session selection must hydrate a full snapshot immediately.
    // Deferred extension pushes remain useful for live updates, but they are
    // not reliable enough to be the only source of signals on initial open or
    // when reselecting an existing session.
    isExtensionsLoading = false

    do {
      let detailScope = activeTransport == .webSocket ? "core" : nil
      let measuredDetail = try await Self.measureOperation {
        try await client.sessionDetail(id: sessionID, scope: detailScope)
      }
      try Task.checkCancellation()
      guard isCurrentSessionLoad(requestID, sessionID: sessionID) else { return }
      recordRequestSuccess()

      var detail = measuredDetail.value
      if let buffered = pendingExtensions, buffered.sessionId == sessionID {
        detail = detail.merging(extensions: buffered)
        pendingExtensions = nil
        isExtensionsLoading = false
      }
      detail = sessionDetailPreservingFresherSelectedSummary(
        sessionID: sessionID,
        detail: detail
      )

      let preserveVisibleTimeline =
        selectedSession?.session.sessionId == sessionID && !timeline.isEmpty
      let preservedTimelineWindow = preserveVisibleTimeline ? timelineWindow : nil
      applySelectedSessionSnapshot(
        sessionID: sessionID,
        detail: detail,
        timeline: preserveVisibleTimeline ? timeline : [],
        timelineWindow: preservedTimelineWindow,
        showingCachedData: false
      )
      isTimelineLoading = !preserveVisibleTimeline

      let timelineRequest = TimelineWindowRequest.latest(
        limit: selectedTimelineRequestLimit(
          loadedTimeline: preserveVisibleTimeline ? timeline : [],
          timelineWindow: preservedTimelineWindow
        ),
        knownRevision: preservedTimelineWindow?.revision
      )
      let measuredTimeline = try await Self.measureOperation {
        try await client.timelineWindow(
          sessionID: sessionID,
          request: timelineRequest
        ) { [weak self] batch, batchIndex, _ in
          await MainActor.run {
            guard let entries = batch.entries else { return }
            self?.applyTimelineBatch(
              entries,
              timelineWindow: batch.metadataOnly,
              index: batchIndex,
              requestID: requestID,
              sessionID: sessionID
            )
          }
        }
      }
      try Task.checkCancellation()
      guard isCurrentSessionLoad(requestID, sessionID: sessionID) else { return }
      recordRequestSuccess()
      let resolvedTimeline = measuredTimeline.value.entries ?? timeline
      let resolvedTimelineWindow = measuredTimeline.value.metadataOnly

      applySelectedSessionSnapshot(
        sessionID: sessionID,
        detail: detail,
        timeline: resolvedTimeline,
        timelineWindow: resolvedTimelineWindow,
        showingCachedData: false
      )
      isTimelineLoading = false
      if !isExtensionsLoading {
        scheduleCacheWrite { service in
          await service.cacheSessionDetail(
            detail,
            timeline: resolvedTimeline,
            timelineWindow: resolvedTimelineWindow
          )
        }
      }
      startSessionSecondaryHydration(
        using: client,
        sessionID: sessionID,
        requestID: requestID
      )
    } catch is CancellationError {
      return
    } catch {
      await handleSessionLoadError(error, requestID: requestID, sessionID: sessionID)
    }
  }

  private func startSessionSecondaryHydration(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String,
    requestID: UInt64
  ) {
    sessionSecondaryHydrationTaskToken &+= 1
    let token = sessionSecondaryHydrationTaskToken
    sessionSecondaryHydrationTask?.cancel()
    sessionSecondaryHydrationTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      defer {
        if self.sessionSecondaryHydrationTaskToken == token {
          self.sessionSecondaryHydrationTask = nil
        }
      }

      guard self.isCurrentSessionLoad(requestID, sessionID: sessionID) else {
        return
      }

      await withTaskGroup(of: Void.self) { group in
        group.addTask { [weak self] in
          guard let self, !Task.isCancelled else {
            return
          }
          _ = await self.refreshCodexRuns(using: client, sessionID: sessionID)
        }
        group.addTask { [weak self] in
          guard let self, !Task.isCancelled else {
            return
          }
          _ = await self.refreshAgentTuis(using: client, sessionID: sessionID)
        }
      }

      guard !Task.isCancelled, self.isCurrentSessionLoad(requestID, sessionID: sessionID) else {
        return
      }

      self.isExtensionsLoading = false
    }
  }

  private func applyTimelineBatch(
    _ batch: [TimelineEntry],
    timelineWindow: TimelineWindowResponse?,
    index batchIndex: Int,
    requestID: UInt64,
    sessionID: String
  ) {
    guard isCurrentSessionLoad(requestID, sessionID: sessionID) else { return }
    applySelectedTimelineBatch(
      batch,
      timelineWindow: timelineWindow,
      index: batchIndex,
      sessionID: sessionID
    )
  }

  func applySelectedTimelineBatch(
    _ batch: [TimelineEntry],
    timelineWindow: TimelineWindowResponse?,
    index batchIndex: Int,
    sessionID: String
  ) {
    guard selectedSessionID == sessionID else { return }

    withUISyncBatch {
      let updatedTimeline: [TimelineEntry]
      if batchIndex == 0 {
        updatedTimeline = batch
      } else {
        var prefix = timeline
        prefix.append(contentsOf: batch)
        updatedTimeline = prefix
      }
      timeline = updatedTimeline
      self.timelineWindow = normalizedTimelineWindow(
        timelineWindow,
        loadedTimeline: updatedTimeline
      )
      isShowingCachedData = false
    }
  }

  private func handleSessionLoadError(
    _ error: any Error,
    requestID: UInt64,
    sessionID: String
  ) async {
    guard isCurrentSessionLoad(requestID, sessionID: sessionID) else { return }
    guard selectedSession?.session.sessionId != sessionID else { return }

    // Background hydration: log silently. The fallback to cached/index data
    // below is the user-visible recovery; we do not surface a toast for an
    // automatic load the user did not explicitly invoke.
    let err = error.localizedDescription
    HarnessMonitorLogger.store.warning(
      "session detail hydration failed for \(sessionID, privacy: .public): \(err, privacy: .public)"
    )
    withUISyncBatch {
      isExtensionsLoading = false
      isTimelineLoading = false
    }

    if let cached = await loadCachedSessionDetail(sessionID: sessionID) {
      applySelectedSessionSnapshot(
        sessionID: sessionID,
        detail: cached.detail,
        timeline: cached.timeline,
        timelineWindow: cached.timelineWindow,
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

  func applySessionIndexSnapshot(
    projects: [ProjectSummary],
    sessions: [SessionSummary]
  ) {
    let selectionMissingFromSnapshot =
      selectedSessionID.map { selectedSessionID in
        sessions.contains { $0.sessionId == selectedSessionID } == false
      } ?? false
    if selectionMissingFromSnapshot {
      primeSessionSelection(nil)
      stopSessionStream()
    }

    var didChange = false
    withUISyncBatch {
      didChange = sessionIndex.replaceSnapshot(projects: projects, sessions: sessions)
      isShowingCachedCatalog = false
    }
    if didChange {
      scheduleCacheWrite { service in
        await service.cacheSessionList(sessions, projects: projects)
      }
    }

    if let selectedSessionID, sessionIndex.sessionSummary(for: selectedSessionID) == nil {
      primeSessionSelection(nil)
      stopSessionStream()
    }
  }

  func applySessionSummaryUpdate(_ summary: SessionSummary) {
    let didChange = sessionIndex.applySessionSummary(summary)
    guard didChange else {
      return
    }
    let project = sessionIndex.projects.first { $0.projectId == summary.projectId }
    scheduleCacheWrite { service in
      await service.cacheSessionSummary(summary, project: project)
    }
  }

  func applySelectedSessionSnapshot(
    sessionID: String,
    detail: SessionDetail,
    timeline: [TimelineEntry],
    timelineWindow: TimelineWindowResponse? = nil,
    showingCachedData: Bool,
    cancelPendingTimelineRefresh: Bool = true
  ) {
    guard selectedSessionID == sessionID else {
      return
    }

    withUISyncBatch {
      selectedSession = detail
      self.timeline = timeline
      self.timelineWindow = normalizedTimelineWindow(
        timelineWindow,
        loadedTimeline: timeline
      )
      applySessionSummaryUpdate(detail.session)
      isShowingCachedData = showingCachedData
      synchronizeActionActor()
    }
    if cancelPendingTimelineRefresh {
      cancelSessionPushFallback(for: sessionID)
    }
  }

  func fallbackTimelineWindow(for timeline: [TimelineEntry]) -> TimelineWindowResponse? {
    guard !timeline.isEmpty else {
      return nil
    }
    return TimelineWindowResponse.fallbackMetadata(for: timeline)
  }

  func selectedTimelineRequestLimit(
    loadedTimeline: [TimelineEntry],
    timelineWindow: TimelineWindowResponse?
  ) -> Int {
    if loadedTimeline.isEmpty == false {
      return max(Self.initialSelectedTimelineWindowLimit, loadedTimeline.count)
    }
    return max(Self.initialSelectedTimelineWindowLimit, timelineWindow?.pageSize ?? 0)
  }

  func normalizedTimelineWindow(
    _ timelineWindow: TimelineWindowResponse?,
    loadedTimeline: [TimelineEntry]
  ) -> TimelineWindowResponse? {
    guard let timelineWindow else {
      return fallbackTimelineWindow(for: loadedTimeline)
    }

    return TimelineWindowResponse(
      revision: timelineWindow.revision,
      totalCount: max(timelineWindow.totalCount, loadedTimeline.count),
      windowStart: 0,
      windowEnd: loadedTimeline.count,
      hasOlder: loadedTimeline.count < timelineWindow.totalCount,
      hasNewer: false,
      oldestCursor: loadedTimeline.last.map(\.timelineCursor),
      newestCursor: loadedTimeline.first.map(\.timelineCursor),
      entries: nil,
      unchanged: timelineWindow.unchanged
    )
  }

}

extension TimelineEntry {
  fileprivate var timelineCursor: TimelineCursor {
    TimelineCursor(recordedAt: recordedAt, entryId: entryId)
  }
}
