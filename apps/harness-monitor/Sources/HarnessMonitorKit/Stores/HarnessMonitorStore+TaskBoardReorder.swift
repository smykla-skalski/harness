import Foundation

extension Error {
  fileprivate var isPositionConcurrentModification: Bool {
    (self as? HarnessMonitorAPIError)?.serverSemanticCode == "WORKFLOW_CONCURRENT"
  }
}

private enum TaskBoardPositionActionError: LocalizedError {
  case boardChanged

  var errorDescription: String? {
    "Cannot update task board position: the board changed before the action completed"
  }
}

public struct TaskBoardOptimisticPositionMutation: Sendable {
  let token: UInt64
  let itemID: String
  let priorItems: [TaskBoardItem]
  let optimisticItems: [TaskBoardItem]
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

  /// Positions an item and changes its lane atomically. The source status is
  /// captured when the action begins so a retry cannot move the item back
  /// after another writer moved it elsewhere.
  @discardableResult
  public func positionTaskBoardItem(
    id: String,
    sourceStatus: TaskBoardStatus,
    destinationStatus: TaskBoardStatus,
    placement: TaskBoardLanePlacement,
    actor: String = "Harness Monitor",
    optimisticMutation: TaskBoardOptimisticPositionMutation? = nil
  ) async -> Bool {
    let resolvedMutation =
      optimisticMutation
      ?? beginOptimisticTaskBoardPosition(
        id: id,
        sourceStatus: sourceStatus,
        destinationStatus: destinationStatus,
        placement: placement,
        actor: actor
      )
    guard
      let resolvedMutation,
      resolvedMutation.itemID == id,
      isPendingTaskBoardPositionMutation(resolvedMutation)
    else {
      return false
    }
    guard let client else {
      rollbackOptimisticTaskBoardPosition(resolvedMutation)
      finishTaskBoardPositionMutation(resolvedMutation)
      return false
    }
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
          PositionPlacement(
            sourceStatus: sourceStatus,
            destinationStatus: destinationStatus,
            placement: placement,
            actor: actor
          ),
          remainingRetries: Self.taskBoardPositionConflictRetryLimit
        )
      }.value
      recordRequestSuccess()
      completeSuccessfulTaskBoardPosition(
        response.snapshot.item,
        mutation: resolvedMutation
      )
      await refreshTaskBoardDashboardSnapshot(using: client)
      return true
    } catch {
      rollbackOptimisticTaskBoardPosition(resolvedMutation)
      finishTaskBoardPositionMutation(resolvedMutation)
      presentFailureFeedback(error.localizedDescription)
      await refreshTaskBoardDashboardSnapshot(using: client)
      return false
    }
  }

  /// Applies the user's drop synchronously so the card settles before the
  /// daemon round trip. The server snapshot remains authoritative and
  /// reconciles this projection after the mutation.
  public func beginOptimisticTaskBoardPosition(
    id: String,
    sourceStatus: TaskBoardStatus,
    destinationStatus: TaskBoardStatus,
    placement: TaskBoardLanePlacement,
    actor: String = "Harness Monitor"
  ) -> TaskBoardOptimisticPositionMutation? {
    let priorItems = globalTaskBoardItems
    guard
      let sourceIndex = priorItems.firstIndex(where: { $0.id == id }),
      priorItems[sourceIndex].deletedAt == nil,
      priorItems[sourceIndex].status.canonicalPersistedStatus
        == sourceStatus.canonicalPersistedStatus
    else {
      return nil
    }
    let canonicalStatus = destinationStatus.canonicalPersistedStatus
    let destinationIDs = priorItems.compactMap { item in
      item.deletedAt == nil && item.status.canonicalPersistedStatus == canonicalStatus
        ? item.id
        : nil
    }
    guard
      let lanePosition = placement.resolvePosition(
        itemID: id,
        orderedItemIDs: destinationIDs
      )
    else {
      return nil
    }

    var optimisticItems = priorItems
    let item = optimisticItems.remove(at: sourceIndex).withOptimisticPosition(
      status: canonicalStatus,
      lanePosition: lanePosition,
      actor: actor
    )
    guard
      let insertionIndex = Self.optimisticInsertionIndex(
        in: optimisticItems,
        status: canonicalStatus,
        placement: placement
      )
    else {
      return nil
    }
    optimisticItems.insert(item, at: insertionIndex)
    guard optimisticItems != priorItems else {
      return nil
    }
    let token = beginTaskBoardPositionMutation()
    globalTaskBoardItems = optimisticItems
    return TaskBoardOptimisticPositionMutation(
      token: token,
      itemID: id,
      priorItems: priorItems,
      optimisticItems: optimisticItems
    )
  }

  private static func optimisticInsertionIndex(
    in items: [TaskBoardItem],
    status: TaskBoardStatus,
    placement: TaskBoardLanePlacement
  ) -> Int? {
    switch placement {
    case .first:
      return items.firstIndex(where: { item in
        item.deletedAt == nil && item.status.canonicalPersistedStatus == status
      }) ?? items.endIndex
    case .last:
      let lastIndex = items.lastIndex(where: { item in
        item.deletedAt == nil && item.status.canonicalPersistedStatus == status
      })
      return lastIndex.map { $0 + 1 } ?? items.endIndex
    case .relative(let relative):
      guard
        let anchorIndex = items.firstIndex(where: { item in
          item.id == relative.anchorItemID
            && item.deletedAt == nil
            && item.status.canonicalPersistedStatus == status
        })
      else {
        return nil
      }
      return relative.edge == .after ? anchorIndex + 1 : anchorIndex
    }
  }

  @discardableResult
  public func reorderTaskBoardItem(
    id: String,
    status: TaskBoardStatus,
    placement: TaskBoardRelativeLanePlacement,
    actor: String = "Harness Monitor"
  ) async -> Bool {
    await positionTaskBoardItem(
      id: id,
      sourceStatus: status,
      destinationStatus: status,
      placement: .relative(placement),
      actor: actor
    )
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
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      await refreshTaskBoardDashboardSnapshot(using: client)
      return false
    }
  }

  /// Recomputes the relative drop against one canonical server snapshot per
  /// attempt, so a bounded retry cannot replay an obsolete absolute slot.
  fileprivate struct PositionPlacement {
    let sourceStatus: TaskBoardStatus
    let destinationStatus: TaskBoardStatus
    let placement: TaskBoardLanePlacement
    let actor: String
  }

  nonisolated fileprivate static func setTaskBoardItemPositionWithRetry(
    using client: any HarnessMonitorClientProtocol,
    id: String,
    _ target: PositionPlacement,
    remainingRetries: Int
  ) async throws -> TaskBoardItemPositionMutationResponse {
    let sourceStatus = target.sourceStatus.canonicalPersistedStatus
    let destinationStatus = target.destinationStatus.canonicalPersistedStatus
    let snapshot = try await client.taskBoardItemsSnapshot(status: nil)
    let request = try taskBoardPositionRequest(
      snapshot: snapshot,
      id: id,
      sourceStatus: sourceStatus,
      destinationStatus: destinationStatus,
      placement: target.placement,
      actor: target.actor
    )
    do {
      return try await client.setTaskBoardItemPosition(id: id, request: request)
    } catch {
      guard remainingRetries > 0, error.isPositionConcurrentModification else {
        throw error
      }
      return try await setTaskBoardItemPositionWithRetry(
        using: client,
        id: id,
        PositionPlacement(
          sourceStatus: sourceStatus,
          destinationStatus: destinationStatus,
          placement: target.placement,
          actor: target.actor
        ),
        remainingRetries: remainingRetries - 1
      )
    }
  }

  nonisolated private static func taskBoardPositionRequest(
    snapshot: TaskBoardListItemsSnapshot,
    id: String,
    sourceStatus: TaskBoardStatus,
    destinationStatus: TaskBoardStatus,
    placement: TaskBoardLanePlacement,
    actor: String
  ) throws -> TaskBoardSetItemPositionRequest {
    let liveItems = snapshot.items.filter { $0.deletedAt == nil }
    let destinationItems = liveItems.filter { item in
      item.status.canonicalPersistedStatus == destinationStatus
    }
    guard
      let item = liveItems.first(where: { $0.id == id }),
      item.status.canonicalPersistedStatus == sourceStatus,
      item.kind != .umbrella,
      let itemRevision = snapshot.itemRevisions[id],
      let lanePosition = placement.resolvePosition(
        itemID: id,
        orderedItemIDs: destinationItems.map(\.id)
      )
    else {
      throw TaskBoardPositionActionError.boardChanged
    }
    if case .relative(let relativePlacement) = placement {
      guard
        let anchor = destinationItems.first(where: {
          $0.id == relativePlacement.anchorItemID
        }),
        anchor.kind != .umbrella
      else {
        throw TaskBoardPositionActionError.boardChanged
      }
    }
    return TaskBoardSetItemPositionRequest(
      status: destinationStatus,
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
      guard remainingRetries > 0, error.isPositionConcurrentModification else {
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
