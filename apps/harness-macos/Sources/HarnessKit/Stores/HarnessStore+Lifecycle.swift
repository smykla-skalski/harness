import Foundation

extension HarnessStore {
  private static let streamRefreshDebounce = Duration.milliseconds(500)
  func connect(using client: any HarnessClientProtocol) async {
    self.client = client
    connectionState = .online

    let transport: TransportKind = client is WebSocketTransport ? .webSocket : .httpSSE
    resetConnectionMetrics(for: transport)
    appendConnectionEvent(kind: .connected, detail: "Connected via \(transport.title)")

    await refresh(using: client, preserveSelection: true)
    guard connectionState == .online else {
      stopAllStreams()
      return
    }
    startConnectionProbe(using: client)
    startGlobalStream(using: client)
    if let selectedSessionID, selectedSession?.session.sessionId == selectedSessionID {
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
    using client: any HarnessClientProtocol,
    preserveSelection: Bool
  ) async {
    isRefreshing = true
    defer { isRefreshing = false }

    do {
      async let healthResponse = Self.measureOperation {
        try await client.health()
      }
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
      let measuredDiagnostics = try await diagnosticsResponse
      let measuredProjects = try await projectResponse
      let measuredSessions = try await sessionResponse

      health = measuredHealth.value
      diagnostics = measuredDiagnostics.value
      projects = measuredProjects.value
      sessions = measuredSessions.value
      daemonStatus = await daemonStatusResponse
      recordRequestSuccess(
        latencyMs: measuredHealth.latencyMs,
        updatesLatency: true
      )
      recordRequestSuccess()
      recordRequestSuccess()
      recordRequestSuccess()
      isShowingCachedData = false
      cacheSessionList(sessions, projects: projects)

      if preserveSelection, let selectedSessionID {
        let requestID = beginSessionLoad()
        await loadSession(using: client, sessionID: selectedSessionID, requestID: requestID)
      } else {
        synchronizeActionActor()
        if shouldAutoSelectPreviewSession(
          client: client,
          sessions: sessions
        ) {
          let requestID = beginSessionLoad()
          await loadSession(using: client, sessionID: sessions[0].sessionId, requestID: requestID)
        }
      }
    } catch {
      markConnectionOffline(error.localizedDescription)

      if let cached = loadCachedSessionList() {
        sessions = cached.sessions
        projects = cached.projects
        isShowingCachedData = true
      }
    }
  }

  func loadSession(
    using client: any HarnessClientProtocol,
    sessionID: String,
    requestID: UInt64
  ) async {
    defer {
      completeSessionLoad(requestID)
    }

    do {
      async let detail = Self.measureOperation {
        try await client.sessionDetail(id: sessionID)
      }
      async let timeline = Self.measureOperation {
        try await client.timeline(sessionID: sessionID)
      }
      let measuredDetail = try await detail
      let measuredTimeline = try await timeline
      let loadedDetail = measuredDetail.value
      let loadedTimeline = measuredTimeline.value
      guard isCurrentSessionLoad(requestID, sessionID: sessionID) else {
        return
      }
      recordRequestSuccess()
      recordRequestSuccess()
      selectedSession = loadedDetail
      self.timeline = loadedTimeline
      isShowingCachedData = false
      synchronizeActionActor()
      cacheSessionDetail(loadedDetail, timeline: loadedTimeline)
    } catch {
      guard isCurrentSessionLoad(requestID, sessionID: sessionID) else {
        return
      }
      lastError = error.localizedDescription

      if let cached = loadCachedSessionDetail(sessionID: sessionID) {
        selectedSession = cached.detail
        timeline = cached.timeline
        isShowingCachedData = true
        synchronizeActionActor()
      }
    }
  }

  private static let streamReconnectDelays: [Duration] = [
    .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8),
  ]

  private func reconnectDelay(for attempt: Int) -> Duration {
    Self.streamReconnectDelays[min(attempt, Self.streamReconnectDelays.count - 1)]
  }

  private func schedulePendingRefresh(
    _ pendingRefresh: inout Task<Void, Never>?,
    action: @escaping @MainActor () async -> Void
  ) {
    pendingRefresh?.cancel()
    pendingRefresh = Task { @MainActor in
      try? await Task.sleep(for: Self.streamRefreshDebounce)
      guard !Task.isCancelled else {
        return
      }
      await action()
    }
  }

  func startGlobalStream(using client: any HarnessClientProtocol) {
    stopGlobalStream()
    globalStreamTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      var attempt = 0
      var pendingRefresh: Task<Void, Never>?
      defer { pendingRefresh?.cancel() }

      while !Task.isCancelled {
        do {
          for try await event in await client.globalStream() {
            recordReconnectRecovery(detail: "Global stream restored")
            attempt = 0
            if event.event == "ready" {
              continue
            }
            recordStreamEvent(countedInTraffic: true)
            schedulePendingRefresh(&pendingRefresh) { [weak self] in
              guard let self else {
                return
              }
              await self.refresh(using: client, preserveSelection: true)
            }
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

  func startSessionStream(using client: any HarnessClientProtocol, sessionID: String) {
    subscribedSessionIDs = [sessionID]
    stopSessionStream(resetSubscriptions: false)
    sessionStreamTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      var attempt = 0
      var pendingRefresh: Task<Void, Never>?
      defer { pendingRefresh?.cancel() }

      while !Task.isCancelled {
        do {
          for try await event in await client.sessionStream(sessionID: sessionID) {
            recordReconnectRecovery(detail: "Session stream restored")
            attempt = 0
            if event.event == "ready" {
              continue
            }
            let countedInTraffic = activeTransport == .httpSSE
            recordStreamEvent(countedInTraffic: countedInTraffic)
            schedulePendingRefresh(&pendingRefresh) { [weak self] in
              guard let self else {
                return
              }
              let requestID = self.beginSessionLoad()
              await self.loadSession(using: client, sessionID: sessionID, requestID: requestID)
            }
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

  private func shouldAutoSelectPreviewSession(
    client: any HarnessClientProtocol,
    sessions: [SessionSummary]
  ) -> Bool {
    selectedSessionID == nil && client is PreviewHarnessClient && !sessions.isEmpty
  }
}
