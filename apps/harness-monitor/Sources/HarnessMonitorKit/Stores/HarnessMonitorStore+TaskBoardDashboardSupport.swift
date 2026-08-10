import Foundation

extension HarnessMonitorStore {
  func mutateTaskBoardPlanning(
    actionName: String,
    mutation:
      @escaping @Sendable (any HarnessMonitorClientProtocol) async throws
      -> TaskBoardPlanningResponse
  ) async -> Bool {
    guard let access = availableTaskBoardClientAccess else {
      return false
    }
    let client = access.client
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }

    do {
      let measuredResponse = try await Self.measureOperation {
        try await mutation(client)
      }
      try requireCurrentTaskBoardClientAccess(access)
      recordRequestSuccess()
      mergeTaskBoardItem(measuredResponse.value.item)
      await refreshTaskBoardDashboardSnapshot(using: client)
      try requireCurrentTaskBoardClientAccess(access)
      presentSuccessFeedback(actionName)
      return true
    } catch is CancellationError {
      return false
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  func mutateTaskBoardOrchestrator(
    actionName: String,
    suppressExpectedCancellation: Bool = false,
    mutation:
      @escaping @Sendable (any HarnessMonitorClientProtocol) async throws
      -> TaskBoardOrchestratorStatus
  ) async -> Bool {
    guard let access = availableTaskBoardClientAccess else {
      return false
    }
    let client = access.client
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }

    do {
      let measuredStatus = try await Self.measureOperation {
        try await mutation(client)
      }
      try requireCurrentTaskBoardClientAccess(access)
      recordRequestSuccess()
      globalTaskBoardOrchestratorStatus = measuredStatus.value
      mergeTaskBoardAutomationSnapshot(measuredStatus.value.automation)
      await refreshTaskBoardDashboardSnapshot(using: client, fallbackStatus: measuredStatus.value)
      try requireCurrentTaskBoardClientAccess(access)
      presentSuccessFeedback(actionName)
      return true
    } catch is CancellationError {
      return false
    } catch {
      if suppressExpectedCancellation && Self.isTaskBoardRunCancellation(error) {
        await refreshTaskBoardDashboardSnapshot(using: client)
        return false
      }
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  nonisolated private static func isTaskBoardRunCancellation(_ error: Error) -> Bool {
    guard let apiError = error as? HarnessMonitorAPIError,
      apiError.serverSemanticCode == "KSRCLI092"
    else {
      return false
    }
    return apiError.serverMessage?.hasSuffix("task-board automation is stopping") == true
  }

  func applyTaskBoardDashboardSnapshot(
    _ snapshot: TaskBoardRefreshSnapshot,
    fallbackStatus: TaskBoardOrchestratorStatus? = nil,
    positionMutationGeneration: UInt64? = nil
  ) {
    let resolvedItems = taskBoardItemsPreservingPositionMutation(
      snapshot.items.value,
      positionMutationGeneration: positionMutationGeneration
    )
    let measuredAutomationSnapshot = snapshot.orchestratorStatus.measured?.value?.automation
    let snapshotStatus =
      if let measuredStatus = snapshot.orchestratorStatus.measured {
        measuredStatus.value ?? fallbackStatus
      } else {
        fallbackStatus ?? globalTaskBoardOrchestratorStatus
      }
    let resolvedStatus = reconcileTaskBoardOrchestratorStatus(
      snapshotStatus,
      snapshotConfirmationRevision: snapshot.stepModeConfirmationRevision
    )
    let didChangeTaskBoardSnapshot =
      globalTaskBoardItems != resolvedItems
      || globalTaskBoardOrchestratorStatus?.withoutAutomationSnapshot
        != resolvedStatus?.withoutAutomationSnapshot

    withUISyncBatch {
      // Explicit task-board refreshes may clear an authoritative empty result, but
      // unavailable endpoints must not erase the last visible board snapshot.
      globalTaskBoardItems = resolvedItems
      globalTaskBoardItemsSnapshotAvailable =
        globalTaskBoardItemsSnapshotAvailable
        || snapshot.items.measured != nil
        || !resolvedItems.isEmpty
      globalTaskBoardOrchestratorStatus = resolvedStatus
      globalTaskBoardProjects = snapshot.projects.value ?? globalTaskBoardProjects
      mergeTaskBoardAutomationSnapshot(measuredAutomationSnapshot)
    }
    if didChangeTaskBoardSnapshot
      && taskBoardRuntimeState.positionMutation.pendingTokens.isEmpty
    {
      scheduleTaskBoardSnapshotCacheWrite(
        items: resolvedItems,
        orchestratorStatus: resolvedStatus
      )
    }
  }

  func taskBoardItemsPreservingPositionMutation(
    _ loadedItems: [TaskBoardItem]?,
    positionMutationGeneration: UInt64?
  ) -> [TaskBoardItem] {
    guard let loadedItems else { return globalTaskBoardItems }
    guard let positionMutationGeneration else {
      return taskBoardRuntimeState.positionMutation.pendingTokens.isEmpty
        ? loadedItems
        : globalTaskBoardItems
    }
    guard canApplyTaskBoardItems(positionMutationGeneration: positionMutationGeneration) else {
      return globalTaskBoardItems
    }
    return loadedItems
  }

  func canApplyTaskBoardItems(positionMutationGeneration: UInt64) -> Bool {
    let mutationState = taskBoardRuntimeState.positionMutation
    return mutationState.pendingTokens.isEmpty
      && mutationState.generation == positionMutationGeneration
  }

  func mergeTaskBoardItem(_ item: TaskBoardItem) {
    guard let index = globalTaskBoardItems.firstIndex(where: { $0.id == item.id }) else {
      globalTaskBoardItems.append(item)
      return
    }
    globalTaskBoardItems[index] = item
  }
}

extension HarnessMonitorStore {
  func rollbackOptimisticTaskBoardPosition(
    _ mutation: TaskBoardOptimisticPositionMutation
  ) {
    guard isCurrentOptimisticTaskBoardPosition(mutation) else { return }
    guard
      let currentIndex = globalTaskBoardItems.firstIndex(where: {
        $0.id == mutation.itemID
      }),
      let priorItem = mutation.priorItems.first(where: {
        $0.id == mutation.itemID
      })
    else {
      return
    }
    var restoredItems = globalTaskBoardItems
    let currentItem = restoredItems.remove(at: currentIndex)
    let restoredItem = currentItem.withTaskBoardPosition(
      status: priorItem.status,
      lanePosition: priorItem.lanePosition,
      laneOrigin: priorItem.laneOrigin,
      laneSetAt: priorItem.laneSetAt
    )
    let insertionIndex = Self.rollbackInsertionIndex(
      in: restoredItems,
      priorItems: mutation.priorItems,
      itemID: mutation.itemID
    )
    restoredItems.insert(restoredItem, at: insertionIndex)
    globalTaskBoardItems = restoredItems
  }

  func completeSuccessfulTaskBoardPosition(
    _ item: TaskBoardItem,
    mutation: TaskBoardOptimisticPositionMutation
  ) {
    guard isPendingTaskBoardPositionMutation(mutation) else { return }
    let shouldMergeResponse = isCurrentOptimisticTaskBoardPosition(mutation)
    finishTaskBoardPositionMutation(mutation)
    if shouldMergeResponse {
      mergeTaskBoardItem(item)
    }
    guard taskBoardRuntimeState.positionMutation.pendingTokens.isEmpty else {
      return
    }
    scheduleTaskBoardSnapshotCacheWrite(
      items: globalTaskBoardItems,
      orchestratorStatus: globalTaskBoardOrchestratorStatus
    )
  }

  func beginTaskBoardPositionMutation() -> UInt64 {
    cancelPendingTaskBoardSnapshotCacheWriteTask()
    let wasIdle = taskBoardRuntimeState.positionMutation.pendingTokens.isEmpty
    taskBoardRuntimeState.positionMutation.generation &+= 1
    let token = taskBoardRuntimeState.positionMutation.generation
    taskBoardRuntimeState.positionMutation.pendingTokens.insert(token)
    if wasIdle {
      scheduleUISync([.contentDashboard])
    }
    return token
  }

  func isPendingTaskBoardPositionMutation(
    _ mutation: TaskBoardOptimisticPositionMutation
  ) -> Bool {
    taskBoardRuntimeState.positionMutation.pendingTokens.contains(mutation.token)
  }

  private func isCurrentOptimisticTaskBoardPosition(
    _ mutation: TaskBoardOptimisticPositionMutation
  ) -> Bool {
    guard
      isPendingTaskBoardPositionMutation(mutation),
      let currentItem = globalTaskBoardItems.first(where: {
        $0.id == mutation.itemID
      }),
      let optimisticItem = mutation.optimisticItems.first(where: {
        $0.id == mutation.itemID
      })
    else {
      return false
    }
    return currentItem.hasSameTaskBoardPosition(as: optimisticItem)
  }

  func finishTaskBoardPositionMutation(
    _ mutation: TaskBoardOptimisticPositionMutation
  ) {
    guard
      taskBoardRuntimeState.positionMutation.pendingTokens.remove(mutation.token) != nil
    else {
      return
    }
    taskBoardRuntimeState.positionMutation.generation &+= 1
    if taskBoardRuntimeState.positionMutation.pendingTokens.isEmpty {
      scheduleUISync([.contentDashboard])
    }
  }

  private static func rollbackInsertionIndex(
    in currentItems: [TaskBoardItem],
    priorItems: [TaskBoardItem],
    itemID: String
  ) -> Int {
    guard let priorIndex = priorItems.firstIndex(where: { $0.id == itemID }) else {
      return currentItems.endIndex
    }
    for item in priorItems[..<priorIndex].reversed() {
      if let index = currentItems.firstIndex(where: { $0.id == item.id }) {
        return index + 1
      }
    }
    let nextIndex = priorItems.index(after: priorIndex)
    for item in priorItems[nextIndex...] {
      if let index = currentItems.firstIndex(where: { $0.id == item.id }) {
        return index
      }
    }
    return currentItems.endIndex
  }
}
