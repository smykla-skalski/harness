import Foundation

extension Error {
  fileprivate var isTaskBoardPositionConcurrentModification: Bool {
    (self as? HarnessMonitorAPIError)?.serverSemanticCode == "WORKFLOW_CONCURRENT"
  }
}

private enum TaskBoardPositionActionError: LocalizedError {
  case boardChanged

  var errorDescription: String? {
    "Cannot update task position: the board changed before the action completed"
  }
}

extension TaskBoardLaneOrigin {
  fileprivate var isManual: Bool {
    if case .manual = self {
      return true
    }
    return false
  }
}

extension HarnessMonitorStore {
  private static let taskBoardPositionConflictRetryLimit = 1

  /// Same-lane drag reorder: refetches the item's own CAS tokens immediately
  /// before sending the set, so the only staleness window is this one
  /// round-trip rather than however long the drag itself took.
  @discardableResult
  public func reorderTaskBoardItem(
    id: String,
    status: TaskBoardStatus,
    placement: TaskBoardRelativeLanePlacement,
    actor: String = "Harness Monitor"
  ) async -> Bool {
    guard let client else { return false }
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }
    do {
      let response = try await Self.measureOperation {
        try await Self.setTaskBoardItemPositionWithRetry(
          using: client,
          id: id,
          status: status,
          placement: placement,
          actor: actor,
          remainingRetries: Self.taskBoardPositionConflictRetryLimit
        )
      }.value
      recordRequestSuccess()
      mergeTaskBoardItem(response.snapshot.item)
      await refreshTaskBoardDashboardSnapshot(using: client)
      presentSuccessFeedback("Reordered task board item")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      await refreshTaskBoardDashboardSnapshot(using: client)
      return false
    }
  }

  /// Reverts a manually placed item back to derived (priority/creation)
  /// ordering, clearing its manual provenance.
  @discardableResult
  public func resetTaskBoardItemManualPosition(
    id: String,
    actor: String = "Harness Monitor"
  ) async -> Bool {
    guard let client else { return false }
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }
    do {
      let response = try await Self.measureOperation {
        try await Self.resetTaskBoardItemPositionWithRetry(
          using: client,
          id: id,
          actor: actor,
          remainingRetries: Self.taskBoardPositionConflictRetryLimit
        )
      }.value
      recordRequestSuccess()
      mergeTaskBoardItem(response.snapshot.item)
      await refreshTaskBoardDashboardSnapshot(using: client)
      presentSuccessFeedback("Reset task board position")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      await refreshTaskBoardDashboardSnapshot(using: client)
      return false
    }
  }

  /// Recomputes the relative drop against one canonical server snapshot per
  /// attempt, so a bounded retry cannot replay an obsolete absolute slot.
  nonisolated static func setTaskBoardItemPositionWithRetry(
    using client: any HarnessMonitorClientProtocol,
    id: String,
    status: TaskBoardStatus,
    placement: TaskBoardRelativeLanePlacement,
    actor: String,
    remainingRetries: Int
  ) async throws -> TaskBoardItemPositionMutationResponse {
    let snapshot = try await client.taskBoardItemsSnapshot(status: status)
    let request = try taskBoardReorderRequest(
      snapshot: snapshot,
      id: id,
      status: status,
      placement: placement,
      actor: actor
    )
    do {
      return try await client.setTaskBoardItemPosition(id: id, request: request)
    } catch {
      guard remainingRetries > 0, error.isTaskBoardPositionConcurrentModification else {
        throw error
      }
      return try await setTaskBoardItemPositionWithRetry(
        using: client,
        id: id,
        status: status,
        placement: placement,
        actor: actor,
        remainingRetries: remainingRetries - 1
      )
    }
  }

  private nonisolated static func taskBoardReorderRequest(
    snapshot: TaskBoardListItemsSnapshot,
    id: String,
    status: TaskBoardStatus,
    placement: TaskBoardRelativeLanePlacement,
    actor: String
  ) throws -> TaskBoardSetItemPositionRequest {
    let statusItems = snapshot.items.filter { item in
      item.status == status && item.deletedAt == nil
    }
    guard
      let item = statusItems.first(where: { $0.id == id }),
      item.kind != .umbrella,
      let anchor = statusItems.first(where: { $0.id == placement.anchorItemID }),
      anchor.kind != .umbrella,
      let itemRevision = snapshot.itemRevisions[id],
      let lanePosition = placement.resolvePosition(
        itemID: id,
        orderedItemIDs: statusItems.map(\.id)
      )
    else {
      throw TaskBoardPositionActionError.boardChanged
    }
    return TaskBoardSetItemPositionRequest(
      status: status,
      lanePosition: lanePosition,
      expectedItemRevision: itemRevision,
      expectedItemsChangeSeq: snapshot.itemsChangeSeq,
      actor: actor
    )
  }

  nonisolated static func resetTaskBoardItemPositionWithRetry(
    using client: any HarnessMonitorClientProtocol,
    id: String,
    actor: String,
    remainingRetries: Int,
    initialItemRevision: Int64? = nil
  ) async throws -> TaskBoardItemPositionMutationResponse {
    let snapshot = try await client.taskBoardItemPositionSnapshot(id: id)
    guard
      snapshot.item.deletedAt == nil,
      snapshot.item.laneOrigin?.isManual == true,
      initialItemRevision == nil || initialItemRevision == snapshot.itemRevision
    else {
      throw TaskBoardPositionActionError.boardChanged
    }
    let request = TaskBoardResetItemPositionRequest(
      expectedItemRevision: snapshot.itemRevision,
      expectedItemsChangeSeq: snapshot.itemsChangeSeq,
      actor: actor
    )
    do {
      return try await client.resetTaskBoardItemPosition(id: id, request: request)
    } catch {
      guard remainingRetries > 0, error.isTaskBoardPositionConcurrentModification else {
        throw error
      }
      return try await resetTaskBoardItemPositionWithRetry(
        using: client,
        id: id,
        actor: actor,
        remainingRetries: remainingRetries - 1,
        initialItemRevision: initialItemRevision ?? snapshot.itemRevision
      )
    }
  }
}
