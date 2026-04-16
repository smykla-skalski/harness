import Foundation

extension HarnessMonitorStore {
  private struct RefreshSnapshot: Sendable {
    let diagnostics: MeasuredOperation<DaemonDiagnosticsReport>
    let projects: MeasuredOperation<[ProjectSummary]>
    let sessions: MeasuredOperation<[SessionSummary]>
  }

  private enum RefreshSnapshotPiece: Sendable {
    case diagnostics(MeasuredOperation<DaemonDiagnosticsReport>)
    case projects(MeasuredOperation<[ProjectSummary]>)
    case sessions(MeasuredOperation<[SessionSummary]>)
  }

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
      _ = disconnectActiveConnection()
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
      let refreshSnapshot = try await Self.loadRefreshSnapshot(using: client)
      let measuredDiagnostics = refreshSnapshot.diagnostics
      let measuredProjects = refreshSnapshot.projects
      let measuredSessions = refreshSnapshot.sessions

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

      schedulePersistedSnapshotHydration(
        using: client,
        sessions: measuredSessions.value
      )
    } catch {
      _ = disconnectActiveConnection()
      markConnectionOffline(error.localizedDescription)
      await restorePersistedSessionState()
    }
  }

  nonisolated private static func loadRefreshSnapshot(
    using client: any HarnessMonitorClientProtocol
  ) async throws -> RefreshSnapshot {
    try await withThrowingTaskGroup(
      of: RefreshSnapshotPiece.self,
      returning: RefreshSnapshot.self
    ) { group in
      group.addTask {
        .diagnostics(
          try await Self.measureOperation {
            try await client.diagnostics()
          }
        )
      }
      group.addTask {
        .projects(
          try await Self.measureOperation {
            try await client.projects()
          }
        )
      }
      group.addTask {
        .sessions(
          try await Self.measureOperation {
            try await client.sessions()
          }
        )
      }

      var diagnostics: MeasuredOperation<DaemonDiagnosticsReport>?
      var projects: MeasuredOperation<[ProjectSummary]>?
      var sessions: MeasuredOperation<[SessionSummary]>?

      for try await piece in group {
        switch piece {
        case .diagnostics(let measuredDiagnostics):
          diagnostics = measuredDiagnostics
        case .projects(let measuredProjects):
          projects = measuredProjects
        case .sessions(let measuredSessions):
          sessions = measuredSessions
        }
      }

      guard let diagnostics, let projects, let sessions else {
        throw CancellationError()
      }

      return RefreshSnapshot(
        diagnostics: diagnostics,
        projects: projects,
        sessions: sessions
      )
    }
  }
}
