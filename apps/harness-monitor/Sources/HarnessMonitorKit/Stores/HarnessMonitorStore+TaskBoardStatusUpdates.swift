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
      let client,
      !taskBoardUpdates.isEmpty || !inboxUpdates.isEmpty,
      inboxUpdates.isEmpty || !isSessionReadOnly,
      !isTaskBoardBusy
    else {
      return false
    }

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
        using: client
      )
    }
    var inboxSucceeded = true
    if !inboxUpdates.isEmpty {
      inboxSucceeded = await performTaskBoardInboxStatusUpdates(
        inboxUpdates,
        actor: actor,
        actionID: "task-board/inbox-status-batch",
        using: client
      )
    }

    guard taskBoardSucceeded, inboxSucceeded else {
      return false
    }
    if !taskBoardUpdates.isEmpty, !inboxUpdates.isEmpty {
      presentSuccessFeedback("Moved task board cards")
    } else if !taskBoardUpdates.isEmpty {
      presentSuccessFeedback(
        taskBoardUpdates.count == 1 ? "Moved task board item" : "Moved task board items"
      )
    } else {
      presentSuccessFeedback(
        inboxUpdates.count == 1 ? "Moved session task" : "Moved session tasks"
      )
    }
    return true
  }

  func performTaskBoardItemStatusUpdates(
    _ updates: [TaskBoardItemStatusUpdate],
    using client: any HarnessMonitorClientProtocol
  ) async -> Bool {
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
        let measuredItem = try await Self.measureOperation {
          try await client.updateTaskBoardItem(
            id: update.id,
            request: TaskBoardUpdateItemRequest(status: update.status)
          )
        }
        recordRequestSuccess()
        reconciledItems.append(measuredItem.value)
      } catch {
        if firstFailure == nil {
          firstFailure = error
        }
        if let priorItem = priorItemsByID[update.id] {
          reconciledItems.append(priorItem)
        }
      }
    }

    withUISyncBatch {
      for item in reconciledItems {
        mergeTaskBoardItem(item)
      }
    }
    await refreshTaskBoardDashboardSnapshot(using: client)
    if let firstFailure {
      presentFailureFeedback(firstFailure.localizedDescription)
      return false
    }
    return true
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
