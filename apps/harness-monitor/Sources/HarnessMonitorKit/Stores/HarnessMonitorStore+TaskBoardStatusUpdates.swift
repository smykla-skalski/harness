import Foundation

extension HarnessMonitorStore {
  @discardableResult
  public func updateTaskBoardItemStatuses(
    _ updates: [TaskBoardItemStatusUpdate]
  ) async -> Bool {
    let updates = deduplicatedTaskBoardItemStatusUpdates(updates)
    guard let client, !updates.isEmpty, !isDaemonActionInFlight else {
      return false
    }
    // Ordering matters: flip in-flight before the optimistic write below,
    // or a re-entrant call could pass the guard above.
    isDaemonActionInFlight = true
    beginTaskBoardAction()
    defer {
      isDaemonActionInFlight = false
      endTaskBoardAction()
    }

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
    presentSuccessFeedback(
      updates.count == 1 ? "Moved task board item" : "Moved task board items"
    )
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

  private func deduplicatedTaskBoardItemStatusUpdates(
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
      externalRefs: externalRefs,
      importedFromProvider: importedFromProvider,
      planning: planning,
      workflow: workflow,
      sessionId: sessionId,
      workItemId: workItemId,
      usage: usage,
      createdAt: createdAt,
      updatedAt: updatedAt,
      deletedAt: deletedAt
    )
  }
}
