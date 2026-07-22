import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
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
      let item = taskBoardItemsStorage[index].withPosition(
        status: request.status,
        lanePosition: request.lanePosition,
        laneOrigin: .manual(actor: request.actor),
        laneSetAt: "2026-07-22T15:00:00Z"
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
    return error
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
      throw HarnessMonitorAPIError.server(code: 409, message: "Task board position is stale")
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
