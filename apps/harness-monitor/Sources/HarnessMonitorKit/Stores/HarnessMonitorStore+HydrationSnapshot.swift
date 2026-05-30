import Foundation

extension HarnessMonitorStore {
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

  public func waitForPersistedSnapshotHydration() async {
    while let task = sessionSnapshotHydrationTask {
      await task.value
    }
  }

  func runPersistedSnapshotHydration(
    using client: any HarnessMonitorClientProtocol,
    sessions: [SessionSummary]
  ) async {
    await Task.yield()
    guard await waitForSessionLoadBeforeHydration() else {
      return
    }

    let prioritySessions = await resolveHydrationPrioritySessions(from: sessions)
    let hydrationQueue = await persistedSnapshotHydrationQueue(for: prioritySessions)
    guard !hydrationQueue.isEmpty else { return }

    var batch: [SessionCacheService.CachedSessionSnapshot] = []
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

  func waitForSessionLoadBeforeHydration() async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while sessionLoadTask != nil {
      guard !Task.isCancelled, connectionState == .online else {
        return false
      }
      guard ContinuousClock.now < deadline else {
        HarnessMonitorLogger.store.warning(
          "Persisted snapshot hydration skipped; foreground session load did not finish"
        )
        return false
      }
      do {
        try await Task.sleep(for: .milliseconds(10))
      } catch {
        return false
      }
    }
    return true
  }

  func resolveHydrationPrioritySessions(
    from sessions: [SessionSummary]
  ) async -> [SessionSummary] {
    guard let cacheService else { return [] }
    let recentIDs = Set(await cacheService.recentlyViewedSessionIDs(limit: 10))
    let selectedSessionID = selectedSessionID
    let selectedSessionNeedsHydration =
      selectedSessionID != nil && (selectedSession == nil || isShowingCachedData)

    var seen = Set<String>()
    var ordered: [SessionSummary] = []
    func append(_ summary: SessionSummary) {
      guard seen.insert(summary.sessionId).inserted else {
        return
      }
      ordered.append(summary)
    }

    for summary in sessions where summary.sessionId == selectedSessionID {
      if selectedSessionNeedsHydration {
        append(summary)
      }
    }
    for summary in sessions where recentIDs.contains(summary.sessionId) {
      append(summary)
    }
    for summary in sessions {
      append(summary)
    }
    return ordered
  }

  func fetchAndApplyHydrationSnapshot(
    using client: any HarnessMonitorClientProtocol,
    summary: SessionSummary,
    batch: inout [SessionCacheService.CachedSessionSnapshot]
  ) async {
    do {
      let detailScope = activeTransport == .webSocket ? "core" : nil
      let expectsDeferredExtensions = detailScope == "core"
      let measuredDetail = try await Self.measureOperation {
        try await client.sessionDetail(id: summary.sessionId, scope: detailScope)
      }
      recordRequestSuccess()
      let detail = sessionDetailPreservingSelectedExtensions(
        sessionID: summary.sessionId,
        detail: measuredDetail.value,
        extensionsPending: expectsDeferredExtensions
      )
      let isSelected = selectedSessionID == summary.sessionId
      let needsUpdate = selectedSession == nil || isShowingCachedData
      let visibleTimelineSnapshot = visiblePresentedTimelineSnapshot(sessionID: summary.sessionId)
      if isSelected && needsUpdate {
        applySelectedSessionSnapshot(
          sessionID: summary.sessionId,
          detail: detail,
          timeline: visibleTimelineSnapshot?.timeline ?? timeline,
          timelineWindow: visibleTimelineSnapshot?.timelineWindow ?? timelineWindow,
          clearBurstState: visibleTimelineSnapshot == nil,
          showingCachedData: false,
          cancelPendingTimelineRefresh: false
        )
      }

      let measuredTimeline = try await Self.measureOperation {
        try await client.timelineWindow(
          sessionID: summary.sessionId,
          request: .latest(limit: Self.initialSelectedTimelineWindowLimit)
        ) { [weak self] batch, batchIndex, _ in
          await MainActor.run {
            guard isSelected && needsUpdate, let entries = batch.entries else { return }
            self?.applySelectedTimelineBatch(
              entries,
              timelineWindow: batch.metadataOnly,
              index: batchIndex,
              sessionID: summary.sessionId
            )
          }
        }
      }
      recordRequestSuccess()
      let resolvedTimeline = measuredTimeline.value.entries ?? []
      let resolvedTimelineWindow = measuredTimeline.value.metadataOnly

      batch.append(
        SessionCacheService.CachedSessionSnapshot(
          detail: detail,
          timeline: resolvedTimeline,
          timelineWindow: resolvedTimelineWindow
        )
      )

      if isSelected && needsUpdate {
        applySelectedSessionSnapshot(
          sessionID: summary.sessionId,
          detail: detail,
          timeline: resolvedTimeline,
          timelineWindow: resolvedTimelineWindow,
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

  func summaryOnlySessionDetail(for summary: SessionSummary) -> SessionDetail {
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
