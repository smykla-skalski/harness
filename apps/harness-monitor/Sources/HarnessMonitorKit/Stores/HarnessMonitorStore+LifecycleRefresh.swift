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

  struct RefreshSnapshot: Sendable {
    let diagnostics: MeasuredOperation<DaemonDiagnosticsReport>
    let projects: MeasuredOperation<[ProjectSummary]>
    let sessions: MeasuredOperation<[SessionSummary]>
    let taskBoardItems: TaskBoardSnapshotLoad<[TaskBoardItem]>
    let taskBoardOrchestratorStatus: TaskBoardSnapshotLoad<TaskBoardOrchestratorStatus?>
  }

  private enum RefreshSnapshotPiece: Sendable {
    case diagnostics(MeasuredOperation<DaemonDiagnosticsReport>)
    case projects(MeasuredOperation<[ProjectSummary]>)
    case sessions(MeasuredOperation<[SessionSummary]>)
    case taskBoardItems(TaskBoardSnapshotLoad<[TaskBoardItem]>)
    case taskBoardOrchestratorStatus(TaskBoardSnapshotLoad<TaskBoardOrchestratorStatus?>)
  }

  func connect(using client: any HarnessMonitorClientProtocol) async {
    if isAppLifecycleSuspended {
      await client.shutdown()
      self.client = nil
      connectionState = .idle
      return
    }
    do {
      _ = try await requireDatabaseBackedTaskBoard(using: client)
    } catch {
      await client.shutdown()
      self.client = nil
      taskBoardDatabaseInstanceID = nil
      markConnectionOffline(Self.describeRefreshSnapshotError(error))
      return
    }
    self.client = client
    await refreshPersistedSessionMetadata()
    _ = await syncStoredTaskBoardCredentialsForNewDaemon(using: client)

    if maintainsLiveDaemonObservation {
      await connectLive(using: client)
      return
    }

    do {
      try await performPreviewConnectRefresh(using: client, preserveSelection: true)
    } catch {
      _ = disconnectActiveConnection()
      markConnectionOffline(Self.describeRefreshSnapshotError(error))
      await restorePersistedSessionState()
      return
    }

    withUISyncBatch {
      connectionState = .online
    }
  }

  private func connectLive(using client: any HarnessMonitorClientProtocol) async {
    withUISyncBatch {
      connectionState = .connecting
    }

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
      markConnectionOnline()
    }
    appendConnectionEvent(kind: .connected, detail: connectedEventDetail(for: transport))
    startConnectionProbe(using: client)
    startManifestWatcher()
    startGlobalStream(using: client)
    if let selectedSessionID {
      startSessionStream(using: client, sessionID: selectedSessionID)
    } else {
      stopSessionStream()
    }
    scheduleSupervisorTick(reason: "connect-live")
  }

  private func performPreviewConnectRefresh(
    using client: any HarnessMonitorClientProtocol,
    preserveSelection: Bool
  ) async throws {
    try await performPreviewRefresh(using: client, preserveSelection: preserveSelection)
  }

  func refresh(
    using client: any HarnessMonitorClientProtocol,
    preserveSelection: Bool,
    allowPreviewReadySelection: Bool = true
  ) async {
    isRefreshing = true
    defer { isRefreshing = false }

    do {
      try await performRefresh(
        using: client,
        preserveSelection: preserveSelection,
        allowPreviewReadySelection: allowPreviewReadySelection,
        isInitialConnect: false
      )
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
        try await performRefresh(
          using: client,
          preserveSelection: preserveSelection,
          isInitialConnect: true
        )
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
        do {
          try await Task.sleep(for: initialConnectRefreshRetryInterval)
        } catch is CancellationError {
          throw CancellationError()
        }
      }
    }
  }

  private func performRefresh(
    using client: any HarnessMonitorClientProtocol,
    preserveSelection: Bool,
    allowPreviewReadySelection: Bool = true,
    recordConnectionTelemetry: Bool = true,
    isInitialConnect: Bool = false
  ) async throws {
    let refreshSnapshot = try await Self.loadRefreshSnapshot(using: client)
    await applyRefreshSnapshot(
      refreshSnapshot,
      using: client,
      options: RefreshApplyOptions(
        preserveSelection: preserveSelection,
        allowPreviewReadySelection: allowPreviewReadySelection,
        recordConnectionTelemetry: recordConnectionTelemetry,
        isInitialConnect: isInitialConnect
      )
    )
  }

  private func performPreviewRefresh(
    using client: any HarnessMonitorClientProtocol,
    preserveSelection: Bool
  ) async throws {
    let refreshSnapshot = try await Self.loadRefreshSnapshot(using: client)
    await applyRefreshSnapshot(
      refreshSnapshot,
      using: client,
      options: RefreshApplyOptions(
        preserveSelection: preserveSelection,
        allowPreviewReadySelection: true,
        recordConnectionTelemetry: false,
        isInitialConnect: false
      )
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
      group.addTask {
        RefreshSnapshotPiece.taskBoardItems(
          await Self.loadTaskBoardItemsSnapshot(using: client)
        )
      }
      group.addTask {
        RefreshSnapshotPiece.taskBoardOrchestratorStatus(
          await Self.loadTaskBoardOrchestratorStatusSnapshot(using: client)
        )
      }

      var diagnostics: MeasuredOperation<DaemonDiagnosticsReport>?
      var projects: MeasuredOperation<[ProjectSummary]>?
      var sessions: MeasuredOperation<[SessionSummary]>?
      var taskBoardItems: TaskBoardSnapshotLoad<[TaskBoardItem]>?
      var taskBoardOrchestratorStatus: TaskBoardSnapshotLoad<TaskBoardOrchestratorStatus?>?

      for try await piece in group {
        switch piece {
        case .diagnostics(let measuredDiagnostics):
          diagnostics = measuredDiagnostics
        case .projects(let measuredProjects):
          projects = measuredProjects
        case .sessions(let measuredSessions):
          sessions = measuredSessions
        case .taskBoardItems(let measuredTaskBoardItems):
          taskBoardItems = measuredTaskBoardItems
        case .taskBoardOrchestratorStatus(let measuredTaskBoardOrchestratorStatus):
          taskBoardOrchestratorStatus = measuredTaskBoardOrchestratorStatus
        }
      }

      guard
        let diagnostics,
        let projects,
        let sessions,
        let taskBoardItems,
        let taskBoardOrchestratorStatus
      else {
        throw CancellationError()
      }

      return RefreshSnapshot(
        diagnostics: diagnostics,
        projects: projects,
        sessions: sessions,
        taskBoardItems: taskBoardItems,
        taskBoardOrchestratorStatus: taskBoardOrchestratorStatus
      )
    }
  }

  nonisolated private static func refreshSnapshotLoadError(
    source: RefreshSnapshotSource,
    underlying error: any Error
  ) -> RefreshSnapshotLoadError {
    let wrapped = RefreshSnapshotLoadError(
      source: source,
      failureDescription: RefreshSnapshotErrorFormatting.describeUnderlying(error)
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
    return RefreshSnapshotErrorFormatting.describeUnderlying(error)
  }
}

struct RefreshApplyOptions {
  let preserveSelection: Bool
  let allowPreviewReadySelection: Bool
  let recordConnectionTelemetry: Bool
  let isInitialConnect: Bool
}

struct TaskBoardConfirmationTick {
  var resolvedItems: [TaskBoardItem]
  var resolvedStatus: TaskBoardOrchestratorStatus?
  var shouldApply: Bool
  var shouldKeepWaiting: Bool
}
