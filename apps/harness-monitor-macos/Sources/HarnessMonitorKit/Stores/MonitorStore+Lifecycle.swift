import Foundation

extension MonitorStore {
  func connect(using client: any MonitorClientProtocol) async {
    self.client = client
    connectionState = .online

    let transport: TransportKind = client is WebSocketTransport ? .webSocket : .httpSSE
    activeTransport = transport
    connectionMetrics.transportKind = transport
    connectionMetrics.connectedSince = Date()
    connectionMetrics.isFallback = transport == .httpSSE
    appendConnectionEvent(kind: .connected, detail: "Connected via \(transport.rawValue)")

    await refresh(using: client, preserveSelection: true)
    startGlobalStream(using: client)
  }

  func appendConnectionEvent(kind: ConnectionEventKind, detail: String) {
    let event = ConnectionEvent(kind: kind, detail: detail, transportKind: activeTransport)
    connectionEvents.append(event)
    if connectionEvents.count > 50 {
      connectionEvents.removeFirst(connectionEvents.count - 50)
    }
  }

  func refresh(
    using client: any MonitorClientProtocol,
    preserveSelection: Bool
  ) async {
    isRefreshing = true
    defer { isRefreshing = false }

    do {
      async let healthResponse = client.health()
      async let diagnosticsResponse = client.diagnostics()
      async let projectResponse = client.projects()
      async let sessionResponse = client.sessions()

      health = try await healthResponse
      diagnostics = try await diagnosticsResponse
      projects = try await projectResponse
      sessions = try await sessionResponse
      daemonStatus = try? await daemonController.daemonStatus()

      fireDataReceivedPulse()
      if preserveSelection, let selectedSessionID {
        await loadSession(using: client, sessionID: selectedSessionID)
      } else {
        synchronizeActionActor()
        if shouldAutoSelectPreviewSession(
          client: client,
          sessions: sessions
        ) {
          await loadSession(using: client, sessionID: sessions[0].sessionId)
        }
      }
    } catch {
      connectionState = .offline(error.localizedDescription)
      lastError = error.localizedDescription
    }
  }

  func loadSession(
    using client: any MonitorClientProtocol,
    sessionID: String
  ) async {
    do {
      async let detail = client.sessionDetail(id: sessionID)
      async let timeline = client.timeline(sessionID: sessionID)
      selectedSession = try await detail
      self.timeline = try await timeline
      synchronizeActionActor()
    } catch {
      lastError = error.localizedDescription
    }
  }

  private static let streamReconnectDelays: [Duration] = [
    .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8),
  ]

  func startGlobalStream(using client: any MonitorClientProtocol) {
    globalStreamTask?.cancel()
    globalStreamTask = Task { [weak self] in
      guard let self else {
        return
      }

      var attempt = 0
      while !Task.isCancelled {
        do {
          var pendingRefresh: Task<Void, Never>?
          for try await event in client.globalStream() {
            attempt = 0
            if event.event == "ready" {
              continue
            }
            pendingRefresh?.cancel()
            pendingRefresh = Task { [weak self] in
              try? await Task.sleep(for: .milliseconds(500))
              guard !Task.isCancelled, let self else { return }
              await self.refresh(using: client, preserveSelection: true)
            }
          }
          pendingRefresh?.cancel()
        } catch {
          if Task.isCancelled { return }
          await MainActor.run {
            self.lastError = error.localizedDescription
          }
        }

        if Task.isCancelled { return }
        let delay = Self.streamReconnectDelays[
          min(attempt, Self.streamReconnectDelays.count - 1)
        ]
        attempt += 1
        try? await Task.sleep(for: delay)
      }
    }
  }

  func fireDataReceivedPulse() {
    dataReceivedPulse = true
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(800))
      dataReceivedPulse = false
    }
  }

  func startSessionStream(using client: any MonitorClientProtocol, sessionID: String) {
    subscribedSessionIDs.insert(sessionID)
    sessionStreamTask?.cancel()
    sessionStreamTask = Task { [weak self] in
      guard let self else {
        return
      }

      var attempt = 0
      while !Task.isCancelled {
        do {
          var pendingRefresh: Task<Void, Never>?
          for try await event in client.sessionStream(sessionID: sessionID) {
            attempt = 0
            if event.event == "ready" {
              continue
            }
            pendingRefresh?.cancel()
            pendingRefresh = Task { [weak self] in
              try? await Task.sleep(for: .milliseconds(500))
              guard !Task.isCancelled, let self else { return }
              await self.loadSession(using: client, sessionID: sessionID)
            }
          }
          pendingRefresh?.cancel()
        } catch {
          if Task.isCancelled { return }
          await MainActor.run {
            self.lastError = error.localizedDescription
          }
        }

        if Task.isCancelled { return }
        let delay = Self.streamReconnectDelays[
          min(attempt, Self.streamReconnectDelays.count - 1)
        ]
        attempt += 1
        try? await Task.sleep(for: delay)
      }
    }
  }

  private func shouldAutoSelectPreviewSession(
    client: any MonitorClientProtocol,
    sessions: [SessionSummary]
  ) -> Bool {
    selectedSessionID == nil && client is PreviewMonitorClient && !sessions.isEmpty
  }
}
