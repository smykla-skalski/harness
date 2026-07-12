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
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    var firstFailure: (any Error)?
    var updatedItems: [TaskBoardItem] = []
    for update in updates {
      do {
        let measuredItem = try await Self.measureOperation {
          try await client.updateTaskBoardItem(
            id: update.id,
            request: TaskBoardUpdateItemRequest(status: update.status)
          )
        }
        recordRequestSuccess()
        updatedItems.append(measuredItem.value)
      } catch {
        if firstFailure == nil {
          firstFailure = error
        }
      }
    }

    withUISyncBatch {
      for item in updatedItems {
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

  private func deduplicatedTaskBoardItemStatusUpdates(
    _ updates: [TaskBoardItemStatusUpdate]
  ) -> [TaskBoardItemStatusUpdate] {
    var seenIDs: Set<String> = []
    return updates.filter { seenIDs.insert($0.id).inserted }
  }
}
