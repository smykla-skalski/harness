import Foundation

extension HarnessMonitorStore {
  private static let sessionPushFallbackDelay = Duration.milliseconds(900)
  private static let streamReconnectDelays: [Duration] = [
    .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8),
  ]
  private static let streamReconnectMaxAttempts = 6

  func connect(using client: any HarnessMonitorClientProtocol) async {
    self.client = client
    connectionState = .online
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
    case .connected:
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
      async let diagnosticsResponse = Self.measureOperation {
        try await client.diagnostics()
      }
      async let projectResponse = Self.measureOperation {
        try await client.projects()
      }
      async let sessionResponse = Self.measureOperation {
        try await client.sessions()
      }

      let measuredDiagnostics = try await diagnosticsResponse
      let measuredProjects = try await projectResponse
      let measuredSessions = try await sessionResponse

      diagnostics = measuredDiagnostics.value
      health = measuredDiagnostics.value.health
      daemonLogLevel = measuredDiagnostics.value.health?.logLevel
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
        Task { @MainActor [weak self] in
          await self?.loadSession(using: client, sessionID: selectedSessionID, requestID: requestID)
        }
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
      async let detailResponse = Self.measureOperation {
        try await client.sessionDetail(id: sessionID, scope: nil)
      }
      async let timelineResponse = Self.measureOperation {
        try await client.timeline(sessionID: sessionID)
      }
      let measuredDetail = try await detailResponse
      let measuredTimeline = try await timelineResponse
      guard isCurrentSessionLoad(requestID, sessionID: sessionID) else {
        return
      }

      recordRequestSuccess()
      recordRequestSuccess()

      var detail = measuredDetail.value
      if let buffered = pendingExtensions, buffered.sessionId == sessionID {
        detail = detail.merging(extensions: buffered)
        pendingExtensions = nil
        isExtensionsLoading = false
      }

      applySelectedSessionSnapshot(
        sessionID: sessionID,
        detail: detail,
        timeline: measuredTimeline.value,
        showingCachedData: false
      )
      if !isExtensionsLoading {
        scheduleCacheWrite { service in
          let insertedCount = await service.cacheSessionDetail(detail, timeline: measuredTimeline.value)
          self.updatePersistedSessionMetadataAfterSave(insertedSessionCount: insertedCount)
        }
      }
    } catch {
      guard isCurrentSessionLoad(requestID, sessionID: sessionID) else {
        return
      }

      if selectedSession?.session.sessionId == sessionID {
        return
      }

      lastError = error.localizedDescription
      isExtensionsLoading = false

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
        isShowingCachedData = persistedSessionCount > 0 || !sessions.isEmpty
      }
    }
  }

  func applySessionIndexSnapshot(
    projects: [ProjectSummary],
    sessions: [SessionSummary]
  ) {
    let didChange = sessionIndex.replaceSnapshot(projects: projects, sessions: sessions)
    isShowingCachedData = false
    if didChange {
      scheduleCacheWrite { service in
        let insertedCount = await service.cacheSessionList(sessions, projects: projects)
        self.updatePersistedSessionMetadataAfterSave(insertedSessionCount: insertedCount)
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

    selectedSession = detail
    self.timeline = timeline
    applySessionSummaryUpdate(detail.session)
    isShowingCachedData = showingCachedData
    synchronizeActionActor()
    if cancelPendingTimelineRefresh {
      cancelSessionPushFallback(for: sessionID)
    }
  }

  private func applyGlobalPushEvent(_ event: DaemonPushEvent) {
    switch event.kind {
    case .ready:
      break
    case .sessionsUpdated(let payload):
      applySessionIndexSnapshot(
        projects: payload.projects,
        sessions: payload.sessions
      )
    case .sessionUpdated(let payload):
      guard let sessionID = event.sessionId else {
        return
      }
      let detail = sessionDetailPreservingSelectedExtensions(
        sessionID: sessionID,
        detail: payload.detail,
        extensionsPending: payload.extensionsPending == true
      )
      if payload.extensionsPending != true {
        isExtensionsLoading = false
      }
      guard sessionID == selectedSessionID else {
        applySessionSummaryUpdate(detail.session)
        if let timeline = payload.timeline {
          scheduleCacheWrite { service in
            let insertedCount = await service.cacheSessionDetail(detail, timeline: timeline, markViewed: false)
            self.updatePersistedSessionMetadataAfterSave(insertedSessionCount: insertedCount)
          }
        }
        return
      }
      let timeline = payload.timeline ?? self.timeline
      applySelectedSessionSnapshot(
        sessionID: sessionID,
        detail: detail,
        timeline: timeline,
        showingCachedData: false,
        cancelPendingTimelineRefresh: payload.timeline != nil
      )
      if let freshTimeline = payload.timeline {
        scheduleCacheWrite { service in
          let insertedCount = await service.cacheSessionDetail(detail, timeline: freshTimeline)
          self.updatePersistedSessionMetadataAfterSave(insertedSessionCount: insertedCount)
        }
      } else if let client {
        scheduleSessionPushFallback(using: client, sessionID: sessionID)
      }
    case .sessionExtensions(let payload):
      applySessionExtensions(payload)
    case .logLevelChanged(let response):
      daemonLogLevel = response.level
    case .unknown:
      break
    }
  }

  private func applySessionPushEvent(_ event: DaemonPushEvent) {
    switch event.kind {
    case .ready, .sessionsUpdated, .logLevelChanged, .unknown:
      break
    case .sessionUpdated(let payload):
      guard let sessionID = event.sessionId else {
        return
      }
      let detail = sessionDetailPreservingSelectedExtensions(
        sessionID: sessionID,
        detail: payload.detail,
        extensionsPending: payload.extensionsPending == true
      )
      if payload.extensionsPending != true {
        isExtensionsLoading = false
      }
      let timeline = payload.timeline ?? self.timeline
      applySelectedSessionSnapshot(
        sessionID: sessionID,
        detail: detail,
        timeline: timeline,
        showingCachedData: false,
        cancelPendingTimelineRefresh: payload.timeline != nil
      )
      if let freshTimeline = payload.timeline {
        scheduleCacheWrite { service in
          let insertedCount = await service.cacheSessionDetail(detail, timeline: freshTimeline)
          self.updatePersistedSessionMetadataAfterSave(insertedSessionCount: insertedCount)
        }
      } else if let client {
        scheduleSessionPushFallback(using: client, sessionID: sessionID)
      }
    case .sessionExtensions(let payload):
      applySessionExtensions(payload)
    }
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
    selectedSession = merged
    isExtensionsLoading = false
    pendingExtensions = nil

    let currentTimeline = timeline
    scheduleCacheWrite { service in
      let insertedCount = await service.cacheSessionDetail(merged, timeline: currentTimeline)
      self.updatePersistedSessionMetadataAfterSave(insertedSessionCount: insertedCount)
    }
  }

  private func sessionDetailPreservingSelectedExtensions(
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

  private func reconnectDelay(for attempt: Int) -> Duration {
    Self.streamReconnectDelays[min(attempt, Self.streamReconnectDelays.count - 1)]
  }

  func startGlobalStream(using client: any HarnessMonitorClientProtocol) {
    stopGlobalStream()
    globalStreamTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      var attempt = 0
      while !Task.isCancelled {
        do {
          for try await event in await client.globalStream() {
            recordReconnectRecovery(detail: "Global stream restored")
            attempt = 0
            recordStreamEvent(countedInTraffic: true)
            if case .ready = event.kind {
              continue
            }
            applyGlobalPushEvent(event)
          }
        } catch {
          if Task.isCancelled {
            return
          }
          recordReconnectAttempt(scope: "global stream", nextAttempt: attempt + 1, error: error)
        }

        if Task.isCancelled {
          return
        }

        if attempt >= Self.streamReconnectMaxAttempts {
          appendConnectionEvent(
            kind: .reconnecting,
            detail: "Global stream failed \(attempt) times, re-bootstrapping"
          )
          await reconnect()
          return
        }

        let delay = reconnectDelay(for: attempt)
        attempt += 1
        try? await Task.sleep(for: delay)
      }
    }
  }

  func startSessionStream(using client: any HarnessMonitorClientProtocol, sessionID: String) {
    subscribedSessionIDs = [sessionID]
    stopSessionStream(resetSubscriptions: false)
    sessionStreamTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      var attempt = 0
      while !Task.isCancelled {
        do {
          for try await event in await client.sessionStream(sessionID: sessionID) {
            recordReconnectRecovery(detail: "Session stream restored")
            attempt = 0
            let countedInTraffic = activeTransport == .httpSSE
            recordStreamEvent(countedInTraffic: countedInTraffic)
            if case .ready = event.kind {
              continue
            }
            applySessionPushEvent(event)
          }
        } catch {
          if Task.isCancelled {
            return
          }
          recordReconnectAttempt(scope: "session stream", nextAttempt: attempt + 1, error: error)
        }

        if Task.isCancelled {
          return
        }

        if attempt >= Self.streamReconnectMaxAttempts {
          appendConnectionEvent(
            kind: .reconnecting,
            detail: "Session stream failed \(attempt) times, re-bootstrapping"
          )
          await reconnect()
          return
        }

        let delay = reconnectDelay(for: attempt)
        attempt += 1
        try? await Task.sleep(for: delay)
      }
    }
  }

  func scheduleSessionPushFallback(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String
  ) {
    // Repeated updates for the same selected session should coalesce into one
    // follow-up timeline refresh instead of continually restarting the timer.
    if pendingSessionPushFallback?.sessionID == sessionID {
      return
    }

    sessionPushFallbackSequence &+= 1
    let token = sessionPushFallbackSequence
    pendingSessionPushFallback = (sessionID: sessionID, token: token)
    sessionPushFallbackTask?.cancel()
    sessionPushFallbackTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      try? await Task.sleep(for: Self.sessionPushFallbackDelay)
      guard !Task.isCancelled else {
        return
      }
      guard
        pendingSessionPushFallback?.token == token,
        pendingSessionPushFallback?.sessionID == sessionID,
        selectedSessionID == sessionID
      else {
        return
      }

      pendingSessionPushFallback = nil
      do {
        let measuredTimeline = try await Self.measureOperation {
          try await client.timeline(sessionID: sessionID)
        }
        recordRequestSuccess()
        guard selectedSessionID == sessionID else {
          return
        }
        timeline = measuredTimeline.value
        if let selectedSession {
          scheduleCacheWrite { service in
            let insertedCount = await service.cacheSessionDetail(selectedSession, timeline: measuredTimeline.value)
            self.updatePersistedSessionMetadataAfterSave(insertedSessionCount: insertedCount)
          }
        }
      } catch {
        lastError = error.localizedDescription
      }
    }
  }

  func cancelSessionPushFallback(for sessionID: String? = nil) {
    guard sessionID == nil || pendingSessionPushFallback?.sessionID == sessionID else {
      return
    }

    pendingSessionPushFallback = nil
    sessionPushFallbackTask?.cancel()
    sessionPushFallbackTask = nil
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

  func startManifestWatcher() {
    stopManifestWatcher()
    let manifestURL = HarnessMonitorPaths.manifestURL()
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let data = FileManager.default.contents(atPath: manifestURL.path),
          let manifest = try? decoder.decode(DaemonManifest.self, from: data)
    else {
      return
    }
    let watcher = ManifestWatcher(currentEndpoint: manifest.endpoint) { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        // Skip if already reconnecting or offline (user stopped daemon)
        guard self.connectionState == .online else { return }
        self.appendConnectionEvent(
          kind: .reconnecting,
          detail: "Daemon manifest changed, re-bootstrapping"
        )
        await self.reconnect()
      }
    }
    manifestWatcher = watcher
    watcher.start()
  }

  func stopManifestWatcher() {
    manifestWatcher?.stop()
    manifestWatcher = nil
  }
}
