import Foundation

extension HarnessMonitorStore {
  private static let sessionPushFallbackDelay = Duration.milliseconds(900)
  private static let streamReconnectDelays: [Duration] = [
    .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8),
  ]

  func connect(using client: any HarnessMonitorClientProtocol) async {
    self.client = client
    connectionState = .online
    refreshPersistedSessionMetadata()

    let transport: TransportKind = client is WebSocketTransport ? .webSocket : .httpSSE
    resetConnectionMetrics(for: transport)
    appendConnectionEvent(kind: .connected, detail: "Connected via \(transport.title)")

    await refresh(using: client, preserveSelection: true)
    guard connectionState == .online else {
      self.client = nil
      stopAllStreams()
      restorePersistedSessionState()
      return
    }
    startConnectionProbe(using: client)
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
  }

  func refresh(
    using client: any HarnessMonitorClientProtocol,
    preserveSelection: Bool
  ) async {
    isRefreshing = true
    defer { isRefreshing = false }

    do {
      async let healthResponse = Self.measureOperation {
        try await client.health()
      }
      async let transportLatencyResponse = client.transportLatencyMs()
      async let diagnosticsResponse = Self.measureOperation {
        try await client.diagnostics()
      }
      async let projectResponse = Self.measureOperation {
        try await client.projects()
      }
      async let sessionResponse = Self.measureOperation {
        try await client.sessions()
      }
      async let daemonStatusResponse: DaemonStatusReport? = try? daemonController.daemonStatus()

      let measuredHealth = try await healthResponse
      let transportLatencyMs = try await transportLatencyResponse
      let measuredDiagnostics = try await diagnosticsResponse
      let measuredProjects = try await projectResponse
      let measuredSessions = try await sessionResponse

      health = measuredHealth.value
      diagnostics = measuredDiagnostics.value
      daemonStatus = await daemonStatusResponse
      recordRequestSuccess(
        latencyMs: transportLatencyMs ?? measuredHealth.latencyMs,
        updatesLatency: true
      )
      recordRequestSuccess()
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
        await loadSession(using: client, sessionID: selectedSessionID, requestID: requestID)
      } else {
        synchronizeActionActor()
        if shouldAutoSelectPreviewSession(
          client: client,
          sessions: measuredSessions.value
        ) {
          let requestID = beginSessionLoad()
          await loadSession(
            using: client,
            sessionID: measuredSessions.value[0].sessionId,
            requestID: requestID
          )
        }
      }
    } catch {
      self.client = nil
      markConnectionOffline(error.localizedDescription)
      restorePersistedSessionState()
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

    do {
      async let detailResponse = Self.measureOperation {
        try await client.sessionDetail(id: sessionID)
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
      applySelectedSessionSnapshot(
        sessionID: sessionID,
        detail: measuredDetail.value,
        timeline: measuredTimeline.value,
        showingCachedData: false
      )
      cacheSessionDetail(measuredDetail.value, timeline: measuredTimeline.value)
    } catch {
      guard isCurrentSessionLoad(requestID, sessionID: sessionID) else {
        return
      }
      lastError = error.localizedDescription

      if let cached = loadCachedSessionDetail(sessionID: sessionID) {
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
    sessionIndex.replaceSnapshot(projects: projects, sessions: sessions)
    isShowingCachedData = false
    cacheSessionList(sessions, projects: projects)

    if let selectedSessionID, sessionIndex.sessionSummary(for: selectedSessionID) == nil {
      primeSessionSelection(nil)
      stopSessionStream()
    }
  }

  func applySessionSummaryUpdate(_ summary: SessionSummary) {
    sessionIndex.applySessionSummary(summary)
    cacheSessionList(sessionIndex.sessions, projects: sessionIndex.projects)
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
      guard sessionID == selectedSessionID else {
        applySessionSummaryUpdate(payload.detail.session)
        if let timeline = payload.timeline {
          cacheSessionDetail(
            payload.detail,
            timeline: timeline,
            markViewed: false
          )
        }
        return
      }
      let timeline = payload.timeline ?? self.timeline
      applySelectedSessionSnapshot(
        sessionID: sessionID,
        detail: payload.detail,
        timeline: timeline,
        showingCachedData: false,
        cancelPendingTimelineRefresh: payload.timeline != nil
      )
      cacheSessionDetail(payload.detail, timeline: timeline)
      if payload.timeline == nil, let client {
        scheduleSessionPushFallback(using: client, sessionID: sessionID)
      }
    case .unknown:
      break
    }
  }

  private func applySessionPushEvent(_ event: DaemonPushEvent) {
    switch event.kind {
    case .ready, .sessionsUpdated, .unknown:
      break
    case .sessionUpdated(let payload):
      guard let sessionID = event.sessionId else {
        return
      }
      let timeline = payload.timeline ?? self.timeline
      applySelectedSessionSnapshot(
        sessionID: sessionID,
        detail: payload.detail,
        timeline: timeline,
        showingCachedData: false,
        cancelPendingTimelineRefresh: payload.timeline != nil
      )
      cacheSessionDetail(payload.detail, timeline: timeline)
      if payload.timeline == nil, let client {
        scheduleSessionPushFallback(using: client, sessionID: sessionID)
      }
    }
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
            if case .ready = event.kind {
              continue
            }
            recordStreamEvent(countedInTraffic: true)
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
            if case .ready = event.kind {
              continue
            }
            let countedInTraffic = activeTransport == .httpSSE
            recordStreamEvent(countedInTraffic: countedInTraffic)
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
          cacheSessionDetail(selectedSession, timeline: measuredTimeline.value)
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

  private func shouldAutoSelectPreviewSession(
    client: any HarnessMonitorClientProtocol,
    sessions: [SessionSummary]
  ) -> Bool {
    selectedSessionID == nil && client is PreviewHarnessClient && !sessions.isEmpty
  }
}
