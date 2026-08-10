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
    let underlyingError: any Error

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
    let taskBoardProjects: TaskBoardSnapshotLoad<[TaskBoardProjectSummary]>
    let stepModeConfirmationRevision: UInt64
    let positionMutationGeneration: UInt64
  }

  private enum RefreshSnapshotPiece: Sendable {
    case diagnostics(MeasuredOperation<DaemonDiagnosticsReport>)
    case projects(MeasuredOperation<[ProjectSummary]>)
    case sessions(MeasuredOperation<[SessionSummary]>)
    case taskBoardItems(TaskBoardSnapshotLoad<[TaskBoardItem]>)
    case taskBoardOrchestratorStatus(TaskBoardSnapshotLoad<TaskBoardOrchestratorStatus?>)
    case taskBoardProjects(TaskBoardSnapshotLoad<[TaskBoardProjectSummary]>)
  }

  func preparePreviewConnectRefresh(
    using client: any HarnessMonitorClientProtocol,
    connectionFence: ConnectionAttemptFence
  ) async throws -> PreparedRefreshApplication {
    let snapshot = try await Self.loadRefreshSnapshot(
      using: client,
      stepModeConfirmationRevision:
        taskBoardRuntimeState.stepModeMutation.confirmationRevision,
      positionMutationGeneration: taskBoardRuntimeState.positionMutation.generation
    )
    guard
      let prepared = await prepareRefreshApplication(
        snapshot,
        connectionFence: connectionFence
      )
    else { throw CancellationError() }
    return prepared
  }

  func refresh(
    using client: any HarnessMonitorClientProtocol,
    preserveSelection: Bool,
    allowPreviewReadySelection: Bool = true
  ) async {
    guard
      self.client === client,
      let connectionFence = try? currentConnectionAttemptFence(),
      let taskBoardAccess = availableTaskBoardClientAccess,
      taskBoardAccess.client === client
    else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    do {
      try await performRefresh(
        using: client,
        preserveSelection: preserveSelection,
        allowPreviewReadySelection: allowPreviewReadySelection,
        isInitialConnect: false,
        connectionFence: connectionFence,
        taskBoardAccess: taskBoardAccess
      )
    } catch {
      guard
        isCurrentConnectionAttemptFence(connectionFence),
        self.client === client,
        taskBoardAccessIsCurrent(taskBoardAccess)
      else { return }
      guard await discardFailedConnectionUnlessReplaced() else { return }
      guard !shouldAbandonConnectionAttempt else {
        connectionState = .idle
        return
      }
      await applyConnectionFailure(error)
    }
  }

  func prepareInitialConnectRefresh(
    using client: any HarnessMonitorClientProtocol,
    connectionFence: ConnectionAttemptFence
  ) async throws -> PreparedRefreshApplication {
    let deadline = ContinuousClock.now.advanced(by: initialConnectRefreshRetryGracePeriod)
    var attempt = 0

    while true {
      guard isCurrentConnectionAttemptFence(connectionFence), !Task.isCancelled else {
        throw CancellationError()
      }
      do {
        let snapshot = try await Self.loadRefreshSnapshot(
          using: client,
          stepModeConfirmationRevision:
            taskBoardRuntimeState.stepModeMutation.confirmationRevision,
          positionMutationGeneration: taskBoardRuntimeState.positionMutation.generation
        )
        guard
          let prepared = await prepareRefreshApplication(
            snapshot,
            connectionFence: connectionFence
          )
        else { throw CancellationError() }
        return prepared
      } catch {
        guard isCurrentConnectionAttemptFence(connectionFence), !Task.isCancelled else {
          throw CancellationError()
        }
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
    isInitialConnect: Bool = false,
    connectionFence: ConnectionAttemptFence? = nil,
    taskBoardAccess: TaskBoardClientAccess
  ) async throws {
    let adoptsLocalManifest = !usesRemoteDaemon
    let stepModeConfirmationRevision =
      taskBoardRuntimeState.stepModeMutation.confirmationRevision
    let positionMutationGeneration =
      taskBoardRuntimeState.positionMutation.generation
    let refreshSnapshot = try await Self.loadRefreshSnapshot(
      using: client,
      stepModeConfirmationRevision: stepModeConfirmationRevision,
      positionMutationGeneration: positionMutationGeneration
    )
    await applyRefreshSnapshot(
      refreshSnapshot,
      using: client,
      options: RefreshApplyOptions(
        preserveSelection: preserveSelection,
        allowPreviewReadySelection: allowPreviewReadySelection,
        recordConnectionTelemetry: recordConnectionTelemetry,
        isInitialConnect: isInitialConnect,
        adoptsLocalManifest: adoptsLocalManifest
      ),
      connectionFence: connectionFence,
      taskBoardAccess: taskBoardAccess
    )
  }

  nonisolated private static func loadRefreshSnapshot(
    using client: any HarnessMonitorClientProtocol,
    stepModeConfirmationRevision: UInt64,
    positionMutationGeneration: UInt64
  ) async throws -> RefreshSnapshot {
    try await withThrowingTaskGroup(
      of: RefreshSnapshotPiece.self,
      returning: RefreshSnapshot.self
    ) { group in
      group.addTask {
        try await Self.loadDiagnosticsSnapshotPiece(using: client)
      }
      group.addTask {
        try await Self.loadProjectsSnapshotPiece(using: client)
      }
      group.addTask {
        try await Self.loadSessionsSnapshotPiece(using: client)
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
      group.addTask {
        RefreshSnapshotPiece.taskBoardProjects(
          await Self.loadTaskBoardProjectsSnapshot(using: client)
        )
      }

      var diagnostics: MeasuredOperation<DaemonDiagnosticsReport>?
      var projects: MeasuredOperation<[ProjectSummary]>?
      var sessions: MeasuredOperation<[SessionSummary]>?
      var taskBoardItems: TaskBoardSnapshotLoad<[TaskBoardItem]>?
      var taskBoardOrchestratorStatus: TaskBoardSnapshotLoad<TaskBoardOrchestratorStatus?>?
      var taskBoardProjects: TaskBoardSnapshotLoad<[TaskBoardProjectSummary]>?

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
        case .taskBoardProjects(let measuredTaskBoardProjects):
          taskBoardProjects = measuredTaskBoardProjects
        }
      }

      guard
        let diagnostics,
        let projects,
        let sessions,
        let taskBoardItems,
        let taskBoardOrchestratorStatus,
        let taskBoardProjects
      else {
        throw CancellationError()
      }

      return RefreshSnapshot(
        diagnostics: diagnostics,
        projects: projects,
        sessions: sessions,
        taskBoardItems: taskBoardItems,
        taskBoardOrchestratorStatus: taskBoardOrchestratorStatus,
        taskBoardProjects: taskBoardProjects,
        stepModeConfirmationRevision: stepModeConfirmationRevision,
        positionMutationGeneration: positionMutationGeneration
      )
    }
  }

  nonisolated private static func loadDiagnosticsSnapshotPiece(
    using client: any HarnessMonitorClientProtocol
  ) async throws -> RefreshSnapshotPiece {
    do {
      return .diagnostics(try await measureOperation { try await client.diagnostics() })
    } catch {
      throw refreshSnapshotLoadError(source: .diagnostics, underlying: error)
    }
  }

  nonisolated private static func loadProjectsSnapshotPiece(
    using client: any HarnessMonitorClientProtocol
  ) async throws -> RefreshSnapshotPiece {
    do {
      return .projects(try await measureOperation { try await client.projects() })
    } catch {
      throw refreshSnapshotLoadError(source: .projects, underlying: error)
    }
  }

  nonisolated private static func loadSessionsSnapshotPiece(
    using client: any HarnessMonitorClientProtocol
  ) async throws -> RefreshSnapshotPiece {
    do {
      return .sessions(try await measureOperation { try await client.sessions() })
    } catch {
      throw refreshSnapshotLoadError(source: .sessions, underlying: error)
    }
  }

  nonisolated private static func refreshSnapshotLoadError(
    source: RefreshSnapshotSource,
    underlying error: any Error
  ) -> RefreshSnapshotLoadError {
    let wrapped = RefreshSnapshotLoadError(
      source: source,
      failureDescription: RefreshSnapshotErrorFormatting.describeUnderlying(error),
      underlyingError: error
    )
    HarnessMonitorLogger.store.warning(
      "\(wrapped.localizedDescription, privacy: .public)"
    )
    return wrapped
  }

  nonisolated static func underlyingRefreshSnapshotError(
    _ error: any Error
  ) -> any Error {
    if let wrapped = error as? RefreshSnapshotLoadError {
      return wrapped.underlyingError
    }
    return error
  }

  nonisolated static func describeRefreshSnapshotError(_ error: any Error) -> String {
    if let wrapped = error as? RefreshSnapshotLoadError {
      return wrapped.localizedDescription
    }
    return RefreshSnapshotErrorFormatting.describeUnderlying(error)
  }
}
