import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func taskBoardItemsSnapshot(status: TaskBoardStatus?) async throws
    -> TaskBoardListItemsSnapshot
  {
    lock.withLock {
      let items = taskBoardItemsStorage.filter { status == nil || $0.status == status }
      return TaskBoardListItemsSnapshot(
        items: items,
        itemsChangeSeq: taskBoardItemsChangeSeqStorage,
        itemRevisions: Dictionary(
          uniqueKeysWithValues: items.map { item in
            (item.id, taskBoardItemRevisionsStorage[item.id, default: 1])
          }
        )
      )
    }
  }

  func taskBoardItemPositionSnapshot(id: String) async throws -> TaskBoardItemPositionSnapshot {
    try lock.withLock {
      guard let item = taskBoardItemsStorage.first(where: { $0.id == id }) else {
        throw HarnessMonitorAPIError.server(code: 404, message: "Task board item unavailable.")
      }
      return TaskBoardItemPositionSnapshot(
        item: item,
        itemRevision: taskBoardItemRevisionsStorage[id, default: 1],
        itemsChangeSeq: taskBoardItemsChangeSeqStorage
      )
    }
  }

  func setTaskBoardItemPosition(
    id: String,
    request: TaskBoardSetItemPositionRequest
  ) async throws -> TaskBoardItemPositionMutationResponse {
    calls.append(
      .setTaskBoardItemPosition(
        id: id,
        status: request.status,
        lanePosition: request.lanePosition
      )
    )
    return try lock.withLock {
      if let error = try dequeuePositionError() {
        throw error
      }
      guard let index = taskBoardItemsStorage.firstIndex(where: { $0.id == id }) else {
        throw HarnessMonitorAPIError.server(code: 404, message: "Task board item unavailable.")
      }
      try ensureExpectedPositionState(
        id: id,
        expectedItemRevision: request.expectedItemRevision,
        expectedItemsChangeSeq: request.expectedItemsChangeSeq
      )
      let laneCount = taskBoardItemsStorage.count { item in
        item.status == request.status && item.deletedAt == nil
      }
      guard Int(request.lanePosition) < laneCount else {
        throw HarnessMonitorAPIError.semanticServer(
          code: 409,
          semanticCode: "TASK_BOARD_LANE_CAPACITY",
          message: "Task board lane capacity changed"
        )
      }
      let item = taskBoardItemsStorage[index].withPosition(
        status: request.status,
        lanePosition: request.lanePosition,
        laneOrigin: .manual(actor: request.actor),
        laneSetAt: "2026-07-22T15:00:00Z"
      )
      replaceInMaterializedLane(item, at: Int(request.lanePosition))
      let revision = bumpPositionState(id: id)
      return TaskBoardItemPositionMutationResponse(
        snapshot: TaskBoardItemPositionSnapshot(
          item: item,
          itemRevision: revision,
          itemsChangeSeq: taskBoardItemsChangeSeqStorage
        ),
        shifted: []
      )
    }
  }

  func resetTaskBoardItemPosition(
    id: String,
    request: TaskBoardResetItemPositionRequest
  ) async throws -> TaskBoardItemPositionMutationResponse {
    calls.append(.resetTaskBoardItemPosition(id: id))
    return try lock.withLock {
      if let error = try dequeuePositionError() {
        throw error
      }
      guard let index = taskBoardItemsStorage.firstIndex(where: { $0.id == id }) else {
        throw HarnessMonitorAPIError.server(code: 404, message: "Task board item unavailable.")
      }
      try ensureExpectedPositionState(
        id: id,
        expectedItemRevision: request.expectedItemRevision,
        expectedItemsChangeSeq: request.expectedItemsChangeSeq
      )
      let item = taskBoardItemsStorage[index].withPosition(
        status: taskBoardItemsStorage[index].status,
        lanePosition: nil,
        laneOrigin: nil,
        laneSetAt: nil
      )
      taskBoardItemsStorage[index] = item
      let revision = bumpPositionState(id: id)
      return TaskBoardItemPositionMutationResponse(
        snapshot: TaskBoardItemPositionSnapshot(
          item: item,
          itemRevision: revision,
          itemsChangeSeq: taskBoardItemsChangeSeqStorage
        ),
        shifted: []
      )
    }
  }

  private func dequeuePositionError() throws -> (any Error)? {
    guard taskBoardPositionErrorRemainingUses > 0, let error = taskBoardPositionError else {
      return nil
    }
    taskBoardPositionErrorRemainingUses -= 1
    applyPositionItemsAfterErrorIfNeeded()
    return error
  }

  private func applyPositionItemsAfterErrorIfNeeded() {
    guard let replacement = taskBoardPositionItemsAfterError else { return }
    let previousByID = Dictionary(uniqueKeysWithValues: taskBoardItemsStorage.map { ($0.id, $0) })
    for item in replacement where previousByID[item.id] != item {
      taskBoardItemRevisionsStorage[item.id, default: 1] += 1
    }
    taskBoardItemsStorage = replacement
    taskBoardItemsChangeSeqStorage += 1
    taskBoardPositionItemsAfterError = nil
  }

  private func replaceInMaterializedLane(_ item: TaskBoardItem, at target: Int) {
    var laneItems = taskBoardItemsStorage.filter { entry in
      entry.status == item.status && entry.id != item.id
    }
    laneItems.insert(item, at: target)
    var laneIndex = 0
    taskBoardItemsStorage = taskBoardItemsStorage.map { entry in
      guard entry.status == item.status else { return entry }
      defer { laneIndex += 1 }
      return laneItems[laneIndex]
    }
  }

  private func ensureExpectedPositionState(
    id: String,
    expectedItemRevision: Int64,
    expectedItemsChangeSeq: Int64
  ) throws {
    guard
      taskBoardItemRevisionsStorage[id, default: 1] == expectedItemRevision,
      taskBoardItemsChangeSeqStorage == expectedItemsChangeSeq
    else {
      throw HarnessMonitorAPIError.semanticServer(
        code: 409,
        semanticCode: "WORKFLOW_CONCURRENT",
        message: "Task board position is stale"
      )
    }
  }

  @discardableResult
  private func bumpPositionState(id: String) -> Int64 {
    let revision = taskBoardItemRevisionsStorage[id, default: 1] + 1
    taskBoardItemRevisionsStorage[id] = revision
    taskBoardItemsChangeSeqStorage += 1
    return revision
  }

}

extension TaskBoardItem {
  fileprivate func withPosition(
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
