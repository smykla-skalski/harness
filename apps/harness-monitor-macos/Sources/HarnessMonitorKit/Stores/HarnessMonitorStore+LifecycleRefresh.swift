// swiftlint:disable file_length
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
    self.client = client
    await refreshPersistedSessionMetadata()
    await syncStoredTaskBoardCredentials(using: client)

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
      preserveSelection: preserveSelection,
      allowPreviewReadySelection: allowPreviewReadySelection,
      recordConnectionTelemetry: recordConnectionTelemetry,
      isInitialConnect: isInitialConnect
    )
  }

  // swiftlint:disable:next function_parameter_count
  private func applyRefreshSnapshot(
    _ refreshSnapshot: RefreshSnapshot,
    using client: any HarnessMonitorClientProtocol,
    preserveSelection: Bool,
    allowPreviewReadySelection: Bool,
    recordConnectionTelemetry: Bool,
    isInitialConnect: Bool
  ) async {
    cancelInitialTaskBoardConfirmationRefresh()
    let measuredDiagnostics = refreshSnapshot.diagnostics
    let measuredProjects = refreshSnapshot.projects
    let measuredSessions = refreshSnapshot.sessions
    let generation = beginSessionIndexSnapshotApply()
    guard
      let filteredSnapshot = await preparedSessionIndexSnapshot(
        projects: measuredProjects.value,
        sessions: measuredSessions.value,
        generation: generation
      )
    else {
      return
    }
    let resolvedTaskBoardSnapshot = resolvedTaskBoardRefreshSnapshot(
      items: refreshSnapshot.taskBoardItems,
      orchestratorStatus: refreshSnapshot.taskBoardOrchestratorStatus,
      isInitialConnect: isInitialConnect
    )
    let didChangeTaskBoardSnapshot =
      globalTaskBoardItems != resolvedTaskBoardSnapshot.items
      || globalTaskBoardOrchestratorStatus != resolvedTaskBoardSnapshot.orchestratorStatus

    withUISyncBatch {
      diagnostics = measuredDiagnostics.value
      health = measuredDiagnostics.value.health
      daemonStatus = DaemonStatusReport(
        diagnosticsReport: measuredDiagnostics.value,
        fallbackProjectCount: filteredSnapshot.projectCount,
        fallbackWorktreeCount: filteredSnapshot.worktreeCount,
        fallbackSessionCount: filteredSnapshot.sessionCount
      )
      daemonLogLevel =
        measuredDiagnostics.value.health?.logLevel
        ?? HarnessMonitorLogger.defaultDaemonLogLevel
      adoptManifestURL(from: measuredDiagnostics.value.workspace.manifestPath)
      globalTaskBoardItems = resolvedTaskBoardSnapshot.items
      globalTaskBoardOrchestratorStatus = resolvedTaskBoardSnapshot.orchestratorStatus
    }
    if didChangeTaskBoardSnapshot {
      scheduleTaskBoardSnapshotCacheWrite(
        items: resolvedTaskBoardSnapshot.items,
        orchestratorStatus: resolvedTaskBoardSnapshot.orchestratorStatus
      )
    }
    if resolvedTaskBoardSnapshot.shouldScheduleConfirmation {
      scheduleInitialTaskBoardConfirmationRefresh(
        using: client,
        preservedItemIDs: resolvedTaskBoardSnapshot.preservedItemIDs,
        preservedStatus: resolvedTaskBoardSnapshot.preservedStatus
      )
    }
    clearTransientHostBridgeIssues()
    if recordConnectionTelemetry {
      recordRequestSuccess(
        latencyMs: measuredDiagnostics.latencyMs,
        latencySource: .request
      )
      recordRequestSuccess()
      recordRequestSuccess()
    }

    applyPreparedSessionIndexSnapshot(filteredSnapshot)

    if preserveSelection, let selectedSessionID, selectedSessionSummary != nil {
      let requestID = beginSessionLoad()
      startSessionLoad(using: client, sessionID: selectedSessionID, requestID: requestID)
    } else {
      synchronizeActionActor()
      if allowPreviewReadySelection,
        let previewReadySessionID = previewReadySessionID(
          client: client,
          sessions: filteredSnapshot.sessions
        )
      {
        Task { @MainActor [weak self] in
          await self?.selectSession(previewReadySessionID)
        }
      }
    }

    schedulePersistedSnapshotHydration(
      using: client,
      sessions: filteredSnapshot.sessions
    )
  }

  private struct ResolvedTaskBoardRefreshSnapshot {
    let items: [TaskBoardItem]
    let orchestratorStatus: TaskBoardOrchestratorStatus?
    let preservedItemIDs: Set<String>
    let preservedStatus: Bool

    var shouldScheduleConfirmation: Bool {
      !preservedItemIDs.isEmpty || preservedStatus
    }
  }

  private func resolvedTaskBoardRefreshSnapshot(
    items: TaskBoardSnapshotLoad<[TaskBoardItem]>,
    orchestratorStatus: TaskBoardSnapshotLoad<TaskBoardOrchestratorStatus?>,
    isInitialConnect: Bool
  ) -> ResolvedTaskBoardRefreshSnapshot {
    let currentItems = globalTaskBoardItems
    let currentStatus = globalTaskBoardOrchestratorStatus
    let resolvedItems: [TaskBoardItem]
    let preservedItemIDs: Set<String>

    if isInitialConnect, !currentItems.isEmpty {
      if let measuredItems = items.measured {
        if measuredItems.value.isEmpty {
          resolvedItems = currentItems
          preservedItemIDs = Set(currentItems.map(\.id))
        } else {
          let liveIDs = Set(measuredItems.value.map(\.id))
          let preservedExternalItems = currentItems.filter { item in
            !item.externalRefs.isEmpty && !liveIDs.contains(item.id)
          }
          resolvedItems = mergedTaskBoardItems(
            measuredItems.value,
            preserving: preservedExternalItems
          )
          preservedItemIDs = Set(preservedExternalItems.map(\.id))
        }
      } else {
        resolvedItems = currentItems
        preservedItemIDs = Set(currentItems.map(\.id))
      }
    } else if let measuredItems = items.measured {
      resolvedItems = measuredItems.value
      preservedItemIDs = []
    } else {
      resolvedItems = currentItems
      preservedItemIDs = []
    }

    let shouldPreserveStatus =
      isInitialConnect
      && currentStatus != nil
      && (orchestratorStatus.measured == nil || orchestratorStatus.measured?.value == nil)
    let resolvedStatus =
      if shouldPreserveStatus {
        currentStatus
      } else if let measuredStatus = orchestratorStatus.measured {
        measuredStatus.value
      } else {
        currentStatus
      }

    return ResolvedTaskBoardRefreshSnapshot(
      items: resolvedItems,
      orchestratorStatus: resolvedStatus,
      preservedItemIDs: preservedItemIDs,
      preservedStatus: shouldPreserveStatus
    )
  }

  private func mergedTaskBoardItems(
    _ liveItems: [TaskBoardItem],
    preserving preservedItems: [TaskBoardItem]
  ) -> [TaskBoardItem] {
    guard !preservedItems.isEmpty else {
      return liveItems
    }
    var mergedItems = liveItems
    var seenIDs = Set(liveItems.map(\.id))
    for item in preservedItems where seenIDs.insert(item.id).inserted {
      mergedItems.append(item)
    }
    return mergedItems
  }

  func cancelInitialTaskBoardConfirmationRefresh() {
    initialTaskBoardConfirmationTask?.cancel()
    initialTaskBoardConfirmationTask = nil
  }

  // swiftlint:disable:next cyclomatic_complexity
  func scheduleInitialTaskBoardConfirmationRefresh(
    using client: any HarnessMonitorClientProtocol,
    preservedItemIDs: Set<String>,
    preservedStatus: Bool
  ) {
    guard !preservedItemIDs.isEmpty || preservedStatus else {
      return
    }
    guard initialTaskBoardConfirmationGracePeriod > .zero else {
      return
    }
    cancelInitialTaskBoardConfirmationRefresh()
    let deadline = ContinuousClock.now.advanced(by: initialTaskBoardConfirmationGracePeriod)
    initialTaskBoardConfirmationTask = Task(priority: .utility) { @MainActor [weak self] in
      guard let self else { return }
      defer { self.initialTaskBoardConfirmationTask = nil }

      while !Task.isCancelled {
        do {
          try await Task.sleep(for: self.taskBoardConfirmationRetryInterval)
        } catch {
          return
        }

        guard
          self.connectionState == .online || self.connectionState == .connecting
        else {
          return
        }

        let snapshot = await Self.loadTaskBoardRefreshSnapshot(using: client)
        let reachedDeadline = ContinuousClock.now >= deadline

        var resolvedItems = self.globalTaskBoardItems
        var resolvedStatus = self.globalTaskBoardOrchestratorStatus
        var shouldApply = false
        var shouldKeepWaiting = false

        if !preservedItemIDs.isEmpty {
          if let measuredItems = snapshot.items.measured {
            let liveIDs = Set(measuredItems.value.map(\.id))
            if preservedItemIDs.isSubset(of: liveIDs) || reachedDeadline {
              resolvedItems = measuredItems.value
              shouldApply = true
            } else {
              shouldKeepWaiting = true
            }
          } else if !reachedDeadline {
            shouldKeepWaiting = true
          }
        }

        if preservedStatus {
          if let measuredStatus = snapshot.orchestratorStatus.measured {
            if measuredStatus.value != nil || reachedDeadline {
              resolvedStatus = measuredStatus.value
              shouldApply = true
            } else {
              shouldKeepWaiting = true
            }
          } else if !reachedDeadline {
            shouldKeepWaiting = true
          }
        }

        if shouldKeepWaiting && !reachedDeadline {
          continue
        }
        guard shouldApply else {
          return
        }
        let didChangeTaskBoardSnapshot =
          self.globalTaskBoardItems != resolvedItems
          || self.globalTaskBoardOrchestratorStatus != resolvedStatus

        withUISyncBatch {
          self.globalTaskBoardItems = resolvedItems
          self.globalTaskBoardOrchestratorStatus = resolvedStatus
        }
        if didChangeTaskBoardSnapshot {
          self.scheduleTaskBoardSnapshotCacheWrite(
            items: resolvedItems,
            orchestratorStatus: resolvedStatus
          )
        }
        return
      }
    }
  }

  private func performPreviewRefresh(
    using client: any HarnessMonitorClientProtocol,
    preserveSelection: Bool
  ) async throws {
    let refreshSnapshot = try await Self.loadRefreshSnapshot(using: client)
    await applyRefreshSnapshot(
      refreshSnapshot,
      using: client,
      preserveSelection: preserveSelection,
      allowPreviewReadySelection: true,
      recordConnectionTelemetry: false,
      isInitialConnect: false
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
