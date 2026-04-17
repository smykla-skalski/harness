import Foundation

extension HarnessMonitorStore {
  private enum RefreshSnapshotSource: String, Sendable {
    case diagnostics
    case projects
    case sessions
  }

  private struct RefreshSnapshotLoadError: LocalizedError, Sendable {
    let source: RefreshSnapshotSource
    let failureDescription: String

    var errorDescription: String? {
      "Startup snapshot \(source.rawValue) failed: \(failureDescription)"
    }
  }

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
    if isAppLifecycleSuspended {
      await client.shutdown()
      self.client = nil
      connectionState = .idle
      return
    }
    self.client = client
    withUISyncBatch {
      connectionState = .connecting
    }
    await refreshPersistedSessionMetadata()

    let transport: TransportKind = client is WebSocketTransport ? .webSocket : .httpSSE
    resetConnectionMetrics(for: transport)

    do {
      try await performInitialConnectRefresh(using: client, preserveSelection: true)
    } catch {
      _ = disconnectActiveConnection()
      markConnectionOffline(Self.describeRefreshSnapshotError(error))
      await restorePersistedSessionState()
      return
    }

    withUISyncBatch {
      connectionState = .online
    }
    appendConnectionEvent(kind: .connected, detail: "Connected via \(transport.title)")
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
      try await performRefresh(using: client, preserveSelection: preserveSelection)
    } catch {
      _ = disconnectActiveConnection()
      markConnectionOffline(Self.describeRefreshSnapshotError(error))
      await restorePersistedSessionState()
    }
  }

  private func performInitialConnectRefresh(
    using client: any HarnessMonitorClientProtocol,
    preserveSelection: Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: initialConnectRefreshRetryGracePeriod)
    var attempt = 0

    while true {
      do {
        try await performRefresh(using: client, preserveSelection: preserveSelection)
        return
      } catch {
        guard ContinuousClock.now < deadline else {
          throw error
        }

        attempt += 1
        let errorDescription = Self.describeRefreshSnapshotError(error)
        appendConnectionEvent(
          kind: .info,
          detail:
            "Daemon health is live, but the startup snapshot is still warming up "
            + "(retry \(attempt)): \(errorDescription)"
        )
        try? await Task.sleep(for: initialConnectRefreshRetryInterval)
      }
    }
  }

  private func performRefresh(
    using client: any HarnessMonitorClientProtocol,
    preserveSelection: Bool
  ) async throws {
    let refreshSnapshot = try await Self.loadRefreshSnapshot(using: client)
    applyRefreshSnapshot(
      refreshSnapshot,
      using: client,
      preserveSelection: preserveSelection
    )
  }

  private func applyRefreshSnapshot(
    _ refreshSnapshot: RefreshSnapshot,
    using client: any HarnessMonitorClientProtocol,
    preserveSelection: Bool
  ) {
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
  }

  nonisolated private static func loadRefreshSnapshot(
    using client: any HarnessMonitorClientProtocol
  ) async throws -> RefreshSnapshot {
    try await withThrowingTaskGroup(
      of: RefreshSnapshotPiece.self,
      returning: RefreshSnapshot.self
    ) { group in
      group.addTask {
        do {
          return .diagnostics(
            try await Self.measureOperation {
              try await client.diagnostics()
            }
          )
        } catch {
          throw Self.refreshSnapshotLoadError(source: .diagnostics, underlying: error)
        }
      }
      group.addTask {
        do {
          return .projects(
            try await Self.measureOperation {
              try await client.projects()
            }
          )
        } catch {
          throw Self.refreshSnapshotLoadError(source: .projects, underlying: error)
        }
      }
      group.addTask {
        do {
          return .sessions(
            try await Self.measureOperation {
              try await client.sessions()
            }
          )
        } catch {
          throw Self.refreshSnapshotLoadError(source: .sessions, underlying: error)
        }
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

  nonisolated private static func refreshSnapshotLoadError(
    source: RefreshSnapshotSource,
    underlying error: any Error
  ) -> RefreshSnapshotLoadError {
    let wrapped = RefreshSnapshotLoadError(
      source: source,
      failureDescription: describeUnderlyingRefreshSnapshotError(error)
    )
    HarnessMonitorLogger.store.warning(
      "\(wrapped.localizedDescription, privacy: .public)"
    )
    return wrapped
  }

  nonisolated private static func describeRefreshSnapshotError(_ error: any Error) -> String {
    if let wrapped = error as? RefreshSnapshotLoadError {
      return wrapped.localizedDescription
    }
    return describeUnderlyingRefreshSnapshotError(error)
  }

  nonisolated private static func describeUnderlyingRefreshSnapshotError(
    _ error: any Error
  ) -> String {
    if let decodingError = error as? DecodingError {
      return describeDecodingError(decodingError)
    }
    return error.localizedDescription
  }

  nonisolated private static func describeDecodingError(
    _ error: DecodingError
  ) -> String {
    switch error {
    case .dataCorrupted(let context):
      let path = describeCodingPath(context.codingPath)
      let description = context.debugDescription
      return
        "decoding failed at \(path): \(description)"
    case .keyNotFound(let key, let context):
      let path = describeCodingPath(context.codingPath + [key])
      let description = context.debugDescription
      return
        "missing key '\(key.stringValue)' at \(path): \(description)"
    case .typeMismatch(let type, let context):
      let path = describeCodingPath(context.codingPath)
      let description = context.debugDescription
      return
        "type mismatch for \(String(describing: type)) at \(path): \(description)"
    case .valueNotFound(let type, let context):
      let path = describeCodingPath(context.codingPath)
      let description = context.debugDescription
      return
        "missing \(String(describing: type)) at \(path): \(description)"
    @unknown default:
      return error.localizedDescription
    }
  }

  nonisolated private static func describeCodingPath(_ codingPath: [CodingKey]) -> String {
    guard !codingPath.isEmpty else {
      return "root"
    }

    var rendered = ""
    for key in codingPath {
      if let index = key.intValue {
        rendered += "[\(index)]"
      } else if rendered.isEmpty {
        rendered = key.stringValue
      } else {
        rendered += ".\(key.stringValue)"
      }
    }
    return rendered
  }
}
