import Foundation

struct PreparedRefreshApplication: Sendable {
  let refreshSnapshot: HarnessMonitorStore.RefreshSnapshot
  let sessionSnapshot: SessionSnapshotWorkerOutput
}

extension HarnessMonitorStore {
  func applyRefreshSnapshot(
    _ refreshSnapshot: RefreshSnapshot,
    using client: any HarnessMonitorClientProtocol,
    options: RefreshApplyOptions,
    connectionFence: ConnectionAttemptFence? = nil,
    taskBoardAccess: TaskBoardClientAccess
  ) async {
    guard
      let prepared = await prepareRefreshApplication(
        refreshSnapshot,
        connectionFence: connectionFence
      ),
      taskBoardAccessIsCurrent(taskBoardAccess)
    else {
      return
    }
    applyPreparedRefreshSnapshot(prepared, using: client, options: options)
  }

  func prepareRefreshApplication(
    _ refreshSnapshot: RefreshSnapshot,
    connectionFence: ConnectionAttemptFence?
  ) async -> PreparedRefreshApplication? {
    guard isCurrentConnectionAttemptFenceIfProvided(connectionFence) else { return nil }
    let generation = beginSessionIndexSnapshotApply()
    guard
      let snapshot = await preparedSessionIndexSnapshot(
        projects: refreshSnapshot.projects.value,
        sessions: refreshSnapshot.sessions.value,
        generation: generation
      ),
      isCurrentConnectionAttemptFenceIfProvided(connectionFence)
    else {
      return nil
    }
    return PreparedRefreshApplication(
      refreshSnapshot: refreshSnapshot,
      sessionSnapshot: snapshot
    )
  }

  func applyPreparedRefreshSnapshot(
    _ prepared: PreparedRefreshApplication,
    using client: any HarnessMonitorClientProtocol,
    options: RefreshApplyOptions
  ) {
    let refreshSnapshot = prepared.refreshSnapshot
    let filteredSnapshot = prepared.sessionSnapshot
    let preserveSelection = options.preserveSelection
    let allowPreviewReadySelection = options.allowPreviewReadySelection
    let recordConnectionTelemetry = options.recordConnectionTelemetry
    cancelInitialTaskBoardConfirmationRefresh()
    let measuredDiagnostics = refreshSnapshot.diagnostics
    let refreshTimings = refreshSnapshot.refreshTimings()
    let resolvedTaskBoardSnapshot = resolvedTaskBoardRefreshSnapshot(
      items: refreshSnapshot.taskBoardItems,
      orchestratorStatus: refreshSnapshot.taskBoardOrchestratorStatus,
      stepModeConfirmationRevision: refreshSnapshot.stepModeConfirmationRevision,
      positionMutationGeneration: refreshSnapshot.positionMutationGeneration,
      isInitialConnect: options.isInitialConnect
    )
    let measuredAutomationSnapshot = refreshSnapshot.taskBoardOrchestratorStatus
      .measured?.value?.automation
    let didChangeTaskBoardSnapshot = taskBoardSnapshotChanged(from: resolvedTaskBoardSnapshot)

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
      if options.adoptsLocalManifest {
        adoptManifestURL(from: measuredDiagnostics.value.workspace.manifestPath)
      }
      globalTaskBoardItems = resolvedTaskBoardSnapshot.items
      globalTaskBoardItemsSnapshotAvailable =
        globalTaskBoardItemsSnapshotAvailable
        || refreshSnapshot.taskBoardItems.measured != nil
        || !resolvedTaskBoardSnapshot.items.isEmpty
      globalTaskBoardOrchestratorStatus = resolvedTaskBoardSnapshot.orchestratorStatus
      globalTaskBoardProjects = refreshSnapshot.taskBoardProjects.value ?? globalTaskBoardProjects
      mergeTaskBoardAutomationSnapshot(measuredAutomationSnapshot)
    }
    if didChangeTaskBoardSnapshot
      && taskBoardRuntimeState.positionMutation.pendingTokens.isEmpty
    {
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
    restoreSelectionAfterRefresh(
      using: client,
      sessions: filteredSnapshot.sessions,
      preserveSelection: preserveSelection,
      allowPreviewReadySelection: allowPreviewReadySelection
    )

    schedulePersistedSnapshotHydration(
      using: client,
      sessions: filteredSnapshot.sessions
    )
  }

  private func restoreSelectionAfterRefresh(
    using client: any HarnessMonitorClientProtocol,
    sessions: [SessionSummary],
    preserveSelection: Bool,
    allowPreviewReadySelection: Bool
  ) {
    if preserveSelection, let selectedSessionID, selectedSessionSummary != nil {
      let requestID = beginSessionLoad()
      startSessionLoad(using: client, sessionID: selectedSessionID, requestID: requestID)
      return
    }
    synchronizeActionActor()
    guard allowPreviewReadySelection,
      let previewReadySessionID = previewReadySessionID(client: client, sessions: sessions)
    else { return }
    Task { @MainActor [weak self] in
      await self?.selectSession(previewReadySessionID)
    }
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

  func taskBoardSnapshotChanged(from snapshot: ResolvedTaskBoardRefreshSnapshot) -> Bool {
    globalTaskBoardItems != snapshot.items
      || globalTaskBoardOrchestratorStatus?.withoutAutomationSnapshot
        != snapshot.orchestratorStatus?.withoutAutomationSnapshot
  }

  func resolvedTaskBoardRefreshSnapshot(
    items: TaskBoardSnapshotLoad<[TaskBoardItem]>,
    orchestratorStatus: TaskBoardSnapshotLoad<TaskBoardOrchestratorStatus?>,
    stepModeConfirmationRevision: UInt64,
    positionMutationGeneration: UInt64,
    isInitialConnect: Bool
  ) -> ResolvedTaskBoardRefreshSnapshot {
    let currentItems = globalTaskBoardItems
    let currentStatus = globalTaskBoardOrchestratorStatus
    let resolvedItems: [TaskBoardItem]
    let preservedItemIDs: Set<String>

    if !canApplyTaskBoardItems(positionMutationGeneration: positionMutationGeneration) {
      resolvedItems = currentItems
      preservedItemIDs = []
    } else if isInitialConnect, !currentItems.isEmpty {
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

    let reconciledStatus = reconcileTaskBoardOrchestratorStatus(
      resolvedStatus,
      snapshotConfirmationRevision: stepModeConfirmationRevision
    )
    return ResolvedTaskBoardRefreshSnapshot(
      items: resolvedItems,
      orchestratorStatus: reconciledStatus,
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
