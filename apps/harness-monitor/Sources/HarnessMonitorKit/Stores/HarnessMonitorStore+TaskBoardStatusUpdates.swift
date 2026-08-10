import Foundation

extension HarnessMonitorStore {
  @discardableResult
  public func updateTaskBoardItemStatuses(
    _ updates: [TaskBoardItemStatusUpdate]
  ) async -> Bool {
    await updateTaskBoardCardStatuses(
      taskBoardUpdates: updates,
      inboxUpdates: []
    )
  }

  @discardableResult
  public func updateTaskBoardCardStatuses(
    taskBoardUpdates: [TaskBoardItemStatusUpdate],
    inboxUpdates: [TaskBoardInboxStatusUpdate],
    actor: String = "harness-app"
  ) async -> Bool {
    let taskBoardUpdates = deduplicatedTaskBoardItemStatusUpdates(taskBoardUpdates)
    let inboxUpdates = deduplicatedTaskBoardInboxStatusUpdates(inboxUpdates)
    guard
      let access = availableTaskBoardClientAccess,
      !taskBoardUpdates.isEmpty || !inboxUpdates.isEmpty,
      inboxUpdates.isEmpty || !isSessionReadOnly,
      !isTaskBoardBusy
    else {
      return false
    }
    let client = access.client

    beginTaskBoardAction()
    if !taskBoardUpdates.isEmpty {
      beginDaemonAction()
    }
    let sessionActionToken =
      inboxUpdates.isEmpty
      ? nil
      : beginSessionAction(actionID: "task-board/inbox-status-batch")
    defer {
      if let sessionActionToken {
        endSessionAction(sessionActionToken)
      }
      if !taskBoardUpdates.isEmpty {
        endDaemonAction()
      }
      endTaskBoardAction()
    }

    var taskBoardSucceeded = true
    if !taskBoardUpdates.isEmpty {
      taskBoardSucceeded = await performTaskBoardItemStatusUpdates(
        taskBoardUpdates,
        access: access
      )
    }
    var inboxSucceeded = true
    if !inboxUpdates.isEmpty {
      guard (try? requireCurrentTaskBoardClientAccess(access)) != nil else { return false }
      inboxSucceeded = await performTaskBoardInboxStatusUpdates(
        inboxUpdates,
        actor: actor,
        actionID: "task-board/inbox-status-batch",
        using: client
      )
      guard (try? requireCurrentTaskBoardClientAccess(access)) != nil else { return false }
    }

    return taskBoardSucceeded && inboxSucceeded
  }

  func performTaskBoardItemStatusUpdates(
    _ updates: [TaskBoardItemStatusUpdate],
    access: TaskBoardClientAccess
  ) async -> Bool {
    let client = access.client
    let priorItemsByID = priorTaskBoardItems(for: updates.map(\.id))
    withUISyncBatch {
      for update in updates {
        guard let priorItem = priorItemsByID[update.id] else {
          continue
        }
        mergeTaskBoardItem(priorItem.withOptimisticStatus(update.status))
      }
    }

    var firstFailure: (any Error)?
    var reconciledItems: [TaskBoardItem] = []
    for update in updates {
      do {
        let item = try await performTaskBoardItemStatusUpdate(
          update,
          priorItem: priorItemsByID[update.id],
          access: access
        )
        reconciledItems.append(item)
      } catch is CancellationError {
        restoreTaskBoardItems(priorItemsByID.values)
        return false
      } catch {
        firstFailure = firstFailure ?? error
        if let priorItem = priorItemsByID[update.id] {
          reconciledItems.append(priorItem)
        }
      }
    }

    guard (try? requireCurrentTaskBoardClientAccess(access)) != nil else {
      restoreTaskBoardItems(priorItemsByID.values)
      return false
    }
    withUISyncBatch {
      for item in reconciledItems {
        mergeTaskBoardItem(item)
      }
    }
    await refreshTaskBoardDashboardSnapshot(using: client, access: access)
    guard taskBoardAccessIsCurrent(access) else { return false }
    if let firstFailure {
      presentFailureFeedback(firstFailure.localizedDescription)
      return false
    }
    return true
  }

  private func performTaskBoardItemStatusUpdate(
    _ update: TaskBoardItemStatusUpdate,
    priorItem: TaskBoardItem?,
    access: TaskBoardClientAccess
  ) async throws -> TaskBoardItem {
    try requireCurrentTaskBoardClientAccess(access)
    let measuredItem = try await Self.measureOperation {
      try await access.client.updateTaskBoardItem(
        id: update.id,
        request: priorItem?.statusUpdateRequest(update.status)
          ?? TaskBoardUpdateItemRequest(status: update.status)
      )
    }
    try requireCurrentTaskBoardClientAccess(access)
    recordRequestSuccess()
    return measuredItem.value
  }

  private func restoreTaskBoardItems<S: Sequence>(_ items: S) where S.Element == TaskBoardItem {
    withUISyncBatch {
      for item in items {
        mergeTaskBoardItem(item)
      }
    }
  }

  private func priorTaskBoardItems(for ids: [String]) -> [String: TaskBoardItem] {
    let idSet = Set(ids)
    var result: [String: TaskBoardItem] = [:]
    result.reserveCapacity(ids.count)
    for item in globalTaskBoardItems where idSet.contains(item.id) {
      result[item.id] = item
    }
    return result
  }

  func deduplicatedTaskBoardItemStatusUpdates(
    _ updates: [TaskBoardItemStatusUpdate]
  ) -> [TaskBoardItemStatusUpdate] {
    var seenIDs: Set<String> = []
    return updates.filter { seenIDs.insert($0.id).inserted }
  }
}

extension TaskBoardItem {
  fileprivate func statusUpdateRequest(_ status: TaskBoardStatus) -> TaskBoardUpdateItemRequest {
    let startsFreshAutomation = status == .todo && workflow?.status.requiresFreshRun == true
    return TaskBoardUpdateItemRequest(
      status: status,
      workflow: startsFreshAutomation ? workflow?.requeued : nil,
      clearSessionId: startsFreshAutomation,
      clearWorkItemId: startsFreshAutomation
    )
  }

  /// Locally-applied status used for optimistic UI feedback before the
  /// server confirms the move. Deliberately keeps `updatedAt` untouched:
  /// the real timestamp arrives with the server response, or the prior
  /// item (also untouched) is restored on failure.
  fileprivate func withOptimisticStatus(_ status: TaskBoardStatus) -> TaskBoardItem {
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
      workspaceId: workspaceId,
      workingCopyId: workingCopyId,
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

extension TaskBoardWorkflowState {
  fileprivate var requeued: TaskBoardWorkflowState {
    TaskBoardWorkflowState(
      prNumber: prNumber,
      prUrl: prUrl,
      prHeadRevision: prHeadRevision,
      prAuthor: prAuthor
    )
  }
}

extension TaskBoardWorkflowStatus {
  fileprivate var requiresFreshRun: Bool {
    switch self {
    case .paused, .completed, .failed, .cancelled:
      true
    case .idle, .running:
      false
    }
  }
}
