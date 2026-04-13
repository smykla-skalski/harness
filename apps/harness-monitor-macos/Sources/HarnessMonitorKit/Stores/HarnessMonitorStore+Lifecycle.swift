import Foundation

extension HarnessMonitorStore {
  func connect(using client: any HarnessMonitorClientProtocol) async {
    self.client = client
    withUISyncBatch {
      connectionState = .online
    }
    await refreshPersistedSessionMetadata()

    let transport: TransportKind = client is WebSocketTransport ? .webSocket : .httpSSE
    resetConnectionMetrics(for: transport)
    appendConnectionEvent(kind: .connected, detail: "Connected via \(transport.title)")

    await refresh(using: client, preserveSelection: true)
    guard connectionState == .online else {
      self.client = nil
      stopAllStreams()
      await restorePersistedSessionState()
      return
    }
    startConnectionProbe(using: client)
    startManifestWatcher()
    startGlobalStream(using: client)
    if let selectedSessionID {
      startSessionStream(using: client, sessionID: selectedSessionID)
    } else {
      stopSessionStream()
    }
  }

  func appendConnectionEvent(kind: ConnectionEventKind, detail: String) {
    let event = ConnectionEvent(kind: kind, detail: detail, transportKind: activeTransport)
    connectionEvents.append(event)
    if connectionEvents.count > 50 {
      connectionEvents.removeFirst(connectionEvents.count - 50)
    }
    switch kind {
    case .connected, .info:
      HarnessMonitorLogger.store.info("\(detail, privacy: .public)")
    case .disconnected, .error:
      HarnessMonitorLogger.store.warning("\(detail, privacy: .public)")
    case .reconnecting, .fallback:
      HarnessMonitorLogger.store.debug("\(detail, privacy: .public)")
    }
  }

  func refresh(
    using client: any HarnessMonitorClientProtocol,
    preserveSelection: Bool
  ) async {
    isRefreshing = true
    defer { isRefreshing = false }

    do {
      // Avoid async-let teardown crashes seen on current macOS Swift runtime.
      let measuredDiagnostics = try await Self.measureOperation {
        try await client.diagnostics()
      }
      let measuredProjects = try await Self.measureOperation {
        try await client.projects()
      }
      let measuredSessions = try await Self.measureOperation {
        try await client.sessions()
      }

      withUISyncBatch {
        diagnostics = measuredDiagnostics.value
        health = measuredDiagnostics.value.health
        daemonStatus = DaemonStatusReport(
          diagnosticsReport: measuredDiagnostics.value,
          fallbackProjectCount: measuredProjects.value.count,
          fallbackWorktreeCount: measuredProjects.value.reduce(0) { $0 + $1.worktrees.count },
          fallbackSessionCount: measuredSessions.value.count
        )
        daemonLogLevel =
          measuredDiagnostics.value.health?.logLevel
          ?? HarnessMonitorLogger.defaultDaemonLogLevel
      }
      recordRequestSuccess(
        latencyMs: measuredDiagnostics.latencyMs,
        updatesLatency: true
      )
      recordRequestSuccess()
      recordRequestSuccess()

      applySessionIndexSnapshot(
        projects: measuredProjects.value,
        sessions: measuredSessions.value
      )
      schedulePersistedSnapshotHydration(
        using: client,
        sessions: measuredSessions.value
      )

      if preserveSelection, let selectedSessionID, selectedSessionSummary != nil {
        let requestID = beginSessionLoad()
        startSessionLoad(using: client, sessionID: selectedSessionID, requestID: requestID)
      } else {
        synchronizeActionActor()
        if let previewReadySessionID = previewReadySessionID(
          client: client,
          sessions: measuredSessions.value
        ) {
          Task { @MainActor [weak self] in
            await self?.selectSession(previewReadySessionID)
          }
        }
      }
    } catch {
      self.client = nil
      markConnectionOffline(error.localizedDescription)
      await restorePersistedSessionState()
    }
  }

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
      guard isCurrentSessionLoad(requestID, sessionID: sessionID) else {
        return
      }

      recordRequestSuccess()

      var detail = measuredDetail.value
      if let buffered = pendingExtensions, buffered.sessionId == sessionID {
        detail = detail.merging(extensions: buffered)
        pendingExtensions = nil
        isExtensionsLoading = false
      }

      let preserveVisibleTimeline =
        isShowingCachedData && selectedSession?.session.sessionId == sessionID
      applySelectedSessionSnapshot(
        sessionID: sessionID,
        detail: detail,
        timeline: preserveVisibleTimeline ? timeline : [],
        showingCachedData: preserveVisibleTimeline
      )

      let measuredTimeline = try await Self.measureOperation {
        try await client.timeline(sessionID: sessionID) { batch, batchIndex, _ in
          await MainActor.run {
            guard self.isCurrentSessionLoad(requestID, sessionID: sessionID) else {
              return
            }

            if batchIndex == 0 {
              self.timeline = batch
            } else {
              var updatedTimeline = self.timeline
              updatedTimeline.append(contentsOf: batch)
              self.timeline = updatedTimeline
            }
            self.isShowingCachedData = false
          }
        }
      }
      try Task.checkCancellation()
      guard isCurrentSessionLoad(requestID, sessionID: sessionID) else {
        return
      }

      recordRequestSuccess()

      applySelectedSessionSnapshot(
        sessionID: sessionID,
        detail: detail,
        timeline: measuredTimeline.value,
        showingCachedData: false
      )
      _ = await refreshCodexRuns(using: client, sessionID: sessionID)
      _ = await refreshAgentTuis(using: client, sessionID: sessionID)
      if !isExtensionsLoading {
        scheduleCacheWrite { service in
          let insertedCount = await service.cacheSessionDetail(
            detail, timeline: measuredTimeline.value)
          self.updatePersistedSessionMetadataAfterSave(insertedSessionCount: insertedCount)
        }
      }
    } catch is CancellationError {
      return
    } catch {
      guard isCurrentSessionLoad(requestID, sessionID: sessionID) else {
        return
      }

      if selectedSession?.session.sessionId == sessionID {
        return
      }

      // Background hydration: log silently. The fallback to cached/index data
      // below is the user-visible recovery; we do not surface a toast for an
      // automatic load the user did not explicitly invoke.
      HarnessMonitorLogger.store.warning(
        "session detail hydration failed for \(sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      withUISyncBatch {
        isExtensionsLoading = false
      }

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
          detail: SessionDetail(
            session: summary,
            agents: [],
            tasks: [],
            signals: [],
            observer: nil,
            agentActivity: []
          ),
          timeline: [],
          showingCachedData: true
        )
      } else {
        withUISyncBatch {
          isShowingCachedData = persistedSessionCount > 0 || !sessions.isEmpty
        }
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
      isShowingCachedData = false
    }
    if didChange {
      scheduleCacheWrite { service in
        _ = await service.cacheSessionList(sessions, projects: projects)
        await self.refreshPersistedSessionMetadata()
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
      let isInsert = await service.cacheSessionSummary(summary, project: project)
      if isInsert {
        self.updatePersistedSessionMetadataAfterSave(insertedSessionCount: 1)
      }
    }
  }

  func applySelectedSessionSnapshot(
    sessionID: String,
    detail: SessionDetail,
    timeline: [TimelineEntry],
    showingCachedData: Bool,
    cancelPendingTimelineRefresh: Bool = true
  ) {
    guard selectedSessionID == sessionID else {
      return
    }

    withUISyncBatch {
      selectedSession = detail
      self.timeline = timeline
      applySessionSummaryUpdate(detail.session)
      isShowingCachedData = showingCachedData
      synchronizeActionActor()
    }
    if cancelPendingTimelineRefresh {
      cancelSessionPushFallback(for: sessionID)
    }
  }

  func sessionDetailPreservingSelectedExtensions(
    sessionID: String,
    detail: SessionDetail,
    extensionsPending: Bool
  ) -> SessionDetail {
    guard extensionsPending,
      sessionID == selectedSessionID,
      let selectedSession
    else {
      return detail
    }

    return SessionDetail(
      session: detail.session,
      agents: detail.agents,
      tasks: detail.tasks,
      signals: selectedSession.signals,
      observer: selectedSession.observer,
      agentActivity: selectedSession.agentActivity
    )
  }

  func applySessionExtensions(_ extensions: SessionExtensionsPayload) {
    guard let sessionID = selectedSessionID,
      sessionID == extensions.sessionId
    else {
      return
    }

    guard let detail = selectedSession else {
      pendingExtensions = extensions
      return
    }

    let merged = detail.merging(extensions: extensions)
    withUISyncBatch {
      selectedSession = merged
      isExtensionsLoading = false
      pendingExtensions = nil
    }

    let currentTimeline = timeline
    scheduleCacheWrite { service in
      let insertedCount = await service.cacheSessionDetail(merged, timeline: currentTimeline)
      self.updatePersistedSessionMetadataAfterSave(insertedSessionCount: insertedCount)
    }
  }

  private func previewReadySessionID(
    client: any HarnessMonitorClientProtocol,
    sessions: [SessionSummary]
  ) -> String? {
    guard
      selectedSessionID == nil,
      let previewClient = client as? PreviewHarnessClient,
      let readySessionID = previewClient.readySessionID,
      sessions.contains(where: { $0.sessionId == readySessionID })
    else {
      return nil
    }

    return readySessionID
  }
}
