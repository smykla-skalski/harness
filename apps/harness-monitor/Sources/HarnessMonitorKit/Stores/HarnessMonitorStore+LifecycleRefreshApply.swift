import Foundation

extension HarnessMonitorStore {
  func applyRefreshSnapshot(
    _ refreshSnapshot: RefreshSnapshot,
    using client: any HarnessMonitorClientProtocol,
    options: RefreshApplyOptions
  ) async {
    let preserveSelection = options.preserveSelection
    let allowPreviewReadySelection = options.allowPreviewReadySelection
    let recordConnectionTelemetry = options.recordConnectionTelemetry
    let isInitialConnect = options.isInitialConnect
    cancelInitialTaskBoardConfirmationRefresh()
    let measuredDiagnostics = refreshSnapshot.diagnostics
    let measuredProjects = refreshSnapshot.projects
    let measuredSessions = refreshSnapshot.sessions
    let refreshTimings = refreshSnapshot.refreshTimings()
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
      lastRefreshTimings = refreshTimings
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

  struct ResolvedTaskBoardRefreshSnapshot {
    let items: [TaskBoardItem]
    let orchestratorStatus: TaskBoardOrchestratorStatus?
    let preservedItemIDs: Set<String>
    let preservedStatus: Bool

    var shouldScheduleConfirmation: Bool {
      !preservedItemIDs.isEmpty || preservedStatus
    }
  }

  func resolvedTaskBoardRefreshSnapshot(
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

  func mergedTaskBoardItems(
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
        guard self.connectionState == .online || self.connectionState == .connecting else {
          return
        }
        let snapshot = await Self.loadTaskBoardRefreshSnapshot(using: client)
        let reachedDeadline = ContinuousClock.now >= deadline
        let tick = self.evaluateTaskBoardConfirmationTick(
          snapshot: snapshot,
          preservedItemIDs: preservedItemIDs,
          preservedStatus: preservedStatus,
          reachedDeadline: reachedDeadline
        )
        if tick.shouldKeepWaiting && !reachedDeadline {
          continue
        }
        guard tick.shouldApply else {
          return
        }
        self.commitTaskBoardConfirmationTick(tick)
        return
      }
    }
  }

  func evaluateTaskBoardConfirmationTick(
    snapshot: TaskBoardRefreshSnapshot,
    preservedItemIDs: Set<String>,
    preservedStatus: Bool,
    reachedDeadline: Bool
  ) -> TaskBoardConfirmationTick {
    var tick = TaskBoardConfirmationTick(
      resolvedItems: globalTaskBoardItems,
      resolvedStatus: globalTaskBoardOrchestratorStatus,
      shouldApply: false,
      shouldKeepWaiting: false
    )
    if !preservedItemIDs.isEmpty {
      resolveTaskBoardItems(
        snapshot: snapshot,
        preservedItemIDs: preservedItemIDs,
        reachedDeadline: reachedDeadline,
        tick: &tick
      )
    }
    if preservedStatus {
      resolveTaskBoardStatus(
        snapshot: snapshot,
        reachedDeadline: reachedDeadline,
        tick: &tick
      )
    }
    return tick
  }

  func resolveTaskBoardItems(
    snapshot: TaskBoardRefreshSnapshot,
    preservedItemIDs: Set<String>,
    reachedDeadline: Bool,
    tick: inout TaskBoardConfirmationTick
  ) {
    guard let measuredItems = snapshot.items.measured else {
      if !reachedDeadline {
        tick.shouldKeepWaiting = true
      }
      return
    }
    let liveIDs = Set(measuredItems.value.map(\.id))
    if preservedItemIDs.isSubset(of: liveIDs) || reachedDeadline {
      tick.resolvedItems = measuredItems.value
      tick.shouldApply = true
    } else {
      tick.shouldKeepWaiting = true
    }
  }

  func resolveTaskBoardStatus(
    snapshot: TaskBoardRefreshSnapshot,
    reachedDeadline: Bool,
    tick: inout TaskBoardConfirmationTick
  ) {
    guard let measuredStatus = snapshot.orchestratorStatus.measured else {
      if !reachedDeadline {
        tick.shouldKeepWaiting = true
      }
      return
    }
    if measuredStatus.value != nil || reachedDeadline {
      tick.resolvedStatus = measuredStatus.value
      tick.shouldApply = true
    } else {
      tick.shouldKeepWaiting = true
    }
  }

  func commitTaskBoardConfirmationTick(_ tick: TaskBoardConfirmationTick) {
    let didChangeTaskBoardSnapshot =
      globalTaskBoardItems != tick.resolvedItems
      || globalTaskBoardOrchestratorStatus != tick.resolvedStatus
    withUISyncBatch {
      self.globalTaskBoardItems = tick.resolvedItems
      self.globalTaskBoardOrchestratorStatus = tick.resolvedStatus
    }
    if didChangeTaskBoardSnapshot {
      scheduleTaskBoardSnapshotCacheWrite(
        items: tick.resolvedItems,
        orchestratorStatus: tick.resolvedStatus
      )
    }
  }
}

extension HarnessMonitorStore.RefreshSnapshot {
  fileprivate func refreshTimings(recordedAt: Date = .now) -> HarnessMonitorRefreshTimings {
    HarnessMonitorRefreshTimings(
      recordedAt: recordedAt,
      diagnosticsLatencyMs: diagnostics.latencyMs,
      projectsLatencyMs: projects.latencyMs,
      sessionsLatencyMs: sessions.latencyMs,
      taskBoardItemsLatencyMs: taskBoardItems.measured?.latencyMs,
      taskBoardOrchestratorLatencyMs: taskBoardOrchestratorStatus.measured?.latencyMs
    )
  }
}
