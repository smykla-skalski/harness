import Foundation

private struct TaskBoardSourceRefreshError: LocalizedError {
  let errorDescription: String?

  init(_ message: String) {
    errorDescription = message
  }
}

extension HarnessMonitorStore {
  func mutateTaskBoardPlanning(
    actionName: String,
    mutation:
      @escaping @Sendable (any HarnessMonitorClientProtocol) async throws
      -> TaskBoardPlanningResponse
  ) async -> Bool {
    guard let client else {
      return false
    }
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
      recordRequestSuccess()
      mergeTaskBoardItem(measuredResponse.value.item)
      await refreshTaskBoardDashboardSnapshot(using: client)
      presentSuccessFeedback(actionName)
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  func mutateTaskBoardOrchestrator(
    actionName: String,
    mutation:
      @escaping @Sendable (any HarnessMonitorClientProtocol) async throws
      -> TaskBoardOrchestratorStatus
  ) async -> Bool {
    guard let client else {
      return false
    }
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
      recordRequestSuccess()
      globalTaskBoardOrchestratorStatus = measuredStatus.value
      mergeTaskBoardAutomationSnapshot(measuredStatus.value.automation)
      await refreshTaskBoardDashboardSnapshot(using: client, fallbackStatus: measuredStatus.value)
      presentSuccessFeedback(actionName)
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
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

  @discardableResult
  func syncAndRefreshTaskBoardDashboard(
    using client: any HarnessMonitorClientProtocol,
    request: TaskBoardSyncRequest,
    successMessage: String? = nil,
    failureMessagePrefix: String? = nil,
    activityKey: String? = nil,
    activityTitle: String? = nil,
    feedbackPosition: ActionFeedback.Position = .topTrailing
  ) async -> Bool {
    updateTaskBoardRefreshActivity(
      key: activityKey,
      title: activityTitle,
      message: "Syncing task sources",
      position: feedbackPosition
    )
    defer { dismissTaskBoardRefreshActivity(key: activityKey) }
    do {
      let measuredSummary = try await Self.measureOperation {
        try await client.syncTaskBoard(request: request)
      }
      recordRequestSuccess()
      globalTaskBoardSyncSummary = measuredSummary.value
      updateTaskBoardRefreshActivity(
        key: activityKey,
        title: activityTitle,
        message: "Board ready · refreshing task sources",
        position: feedbackPosition
      )
      await refreshTaskBoardDashboardSnapshot(using: client)
      let completion = try await waitForTaskBoardSourceRefresh(using: client)
      if taskBoardSyncPhase == .stopping || completion.cancelled {
        await finishStoppedTaskBoardSync(using: client, position: feedbackPosition)
        return false
      }
      if let error = completion.error {
        throw TaskBoardSourceRefreshError(error)
      }
      if let summary = completion.summary {
        globalTaskBoardSyncSummary = summary
      }
      updateTaskBoardRefreshActivity(
        key: activityKey,
        title: activityTitle,
        message: "Loading refreshed tasks",
        position: feedbackPosition
      )
      await refreshTaskBoardDashboardSnapshot(using: client)
      if let successMessage {
        presentSuccessFeedback(successMessage, position: feedbackPosition)
      }
      return true
    } catch is CancellationError {
      if taskBoardSyncPhase == .stopping {
        await finishStoppedTaskBoardSync(using: client, position: feedbackPosition)
      }
      return false
    } catch {
      if taskBoardSyncPhase == .stopping {
        await finishStoppedTaskBoardSync(using: client, position: feedbackPosition)
        return false
      }
      updateTaskBoardRefreshActivity(
        key: activityKey,
        title: activityTitle,
        message: "Reloading current tasks",
        position: feedbackPosition
      )
      await refreshTaskBoardDashboardSnapshot(using: client)
      let failureDescription =
        if let failureMessagePrefix {
          "\(failureMessagePrefix): \(error.localizedDescription)"
        } else {
          error.localizedDescription
        }
      presentFailureFeedback(failureDescription, position: feedbackPosition)
      return false
    }
  }

  private func waitForTaskBoardSourceRefresh(
    using client: any HarnessMonitorClientProtocol
  ) async throws -> TaskBoardSyncStatusResponse {
    while true {
      let status = try await client.taskBoardSyncStatus()
      guard status.active else { return status }
      if taskBoardSyncPhase == .stopping, !status.cancellationRequested {
        _ = try await client.cancelTaskBoardSync()
      }
      try Task.checkCancellation()
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private func finishStoppedTaskBoardSync(
    using client: any HarnessMonitorClientProtocol,
    position: ActionFeedback.Position
  ) async {
    await refreshTaskBoardDashboardSnapshot(using: client)
    presentSuccessFeedback("Task source refresh stopped", position: position)
  }

  private func updateTaskBoardRefreshActivity(
    key: String?,
    title: String?,
    message: String,
    position: ActionFeedback.Position
  ) {
    guard let key else { return }
    toast.updateActivity(
      key: key,
      message: message,
      title: title,
      position: position
    )
  }

  private func dismissTaskBoardRefreshActivity(key: String?) {
    guard let key else { return }
    toast.dismissActivity(key: key)
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

extension TaskBoardItem {
  func withOptimisticPosition(
    status: TaskBoardStatus,
    lanePosition: UInt32,
    actor: String
  ) -> TaskBoardItem {
    withTaskBoardPosition(
      status: status,
      lanePosition: lanePosition,
      laneOrigin: .manual(actor: actor),
      laneSetAt: laneSetAt
    )
  }

  fileprivate func hasSameTaskBoardPosition(as other: TaskBoardItem) -> Bool {
    status == other.status
      && lanePosition == other.lanePosition
      && laneOrigin == other.laneOrigin
      && laneSetAt == other.laneSetAt
  }

  fileprivate func withTaskBoardPosition(
    status: TaskBoardStatus,
    lanePosition: UInt32?,
    laneOrigin: TaskBoardLaneOrigin?,
    laneSetAt: String?
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: schemaVersion,
      id: id,
      title: title,
      body: body,
      status: status,
      priority: priority,
      tags: tags,
      projectId: projectId,
      sourceProjectId: sourceProjectId,
      executionRepository: executionRepository,
      targetProjectTypes: targetProjectTypes,
      agentMode: agentMode,
      kind: kind,
      externalRefs: externalRefs,
      importedFromProvider: importedFromProvider,
      planning: planning,
      workflow: workflow,
      sessionId: sessionId,
      workItemId: workItemId,
      usage: usage,
      parentItemId: parentItemId,
      childOrder: childOrder,
      lanePosition: lanePosition,
      laneOrigin: laneOrigin,
      laneSetAt: laneSetAt,
      createdAt: createdAt,
      updatedAt: updatedAt,
      deletedAt: deletedAt
    )
  }
}
