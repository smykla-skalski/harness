import Foundation

extension PreviewHarnessClientState {
  func taskBoardItemsSnapshot(status: TaskBoardStatus?) -> TaskBoardListItemsSnapshot {
    let items = currentTaskBoardItems(status: status)
    let itemIDs = Set(items.map(\.id))
    return TaskBoardListItemsSnapshot(
      items: items,
      itemsChangeSeq: taskBoardItemsChangeSeq,
      itemRevisions: taskBoardItemRevisions.filter { itemIDs.contains($0.key) }
    )
  }

  func taskBoardItemPositionSnapshot(id: String) throws -> TaskBoardItemPositionSnapshot {
    let item = try currentTaskBoardItem(id: id)
    guard item.deletedAt == nil, let revision = taskBoardItemRevisions[id] else {
      throw taskBoardPositionUnavailable()
    }
    return TaskBoardItemPositionSnapshot(
      item: item,
      itemRevision: revision,
      itemsChangeSeq: taskBoardItemsChangeSeq
    )
  }

  func setTaskBoardItemPosition(
    id: String,
    request: TaskBoardSetItemPositionRequest
  ) throws -> TaskBoardItemPositionMutationResponse {
    try requireCurrentPositionSnapshot(
      id, request.expectedItemRevision, request.expectedItemsChangeSeq)
    let current = try currentTaskBoardItem(id: id)
    try ensurePositionMutable(current)
    let source = current.status.canonicalPersistedStatus
    let destination = request.status.canonicalPersistedStatus
    let sourceIndex =
      current.lanePosition
      ?? materializedLanePosition(for: current, in: source)
    let candidates = taskBoardItems.filter {
      $0.id != id && $0.status.canonicalPersistedStatus == destination && $0.deletedAt == nil
    }
    guard request.lanePosition <= UInt32(candidates.count) else {
      throw HarnessMonitorAPIError.server(code: 409, message: "Task board lane capacity changed")
    }
    let shifted = shiftForSet(
      itemID: id,
      source: source,
      sourceIndex: sourceIndex,
      destination: destination,
      destinationIndex: request.lanePosition
    )
    replacePosition(
      current,
      status: destination,
      lanePosition: request.lanePosition,
      laneOrigin: .manual(actor: request.actor),
      laneSetAt: Self.mutationTimestamp,
      updatedAt: Self.mutationTimestamp
    )
    taskBoardItemsChangeSeq += 1
    return TaskBoardItemPositionMutationResponse(
      snapshot: try taskBoardItemPositionSnapshot(id: id),
      shifted: shifted
    )
  }

  func resetTaskBoardItemPosition(
    id: String,
    request: TaskBoardResetItemPositionRequest
  ) throws -> TaskBoardItemPositionMutationResponse {
    try requireCurrentPositionSnapshot(
      id, request.expectedItemRevision, request.expectedItemsChangeSeq)
    let current = try currentTaskBoardItem(id: id)
    try ensurePositionMutable(current)
    guard let index = current.lanePosition else {
      throw HarnessMonitorAPIError.server(
        code: 400, message: "Task board item has no explicit position")
    }
    let shifted = shiftLaterAnchors(
      in: current.status.canonicalPersistedStatus,
      after: index,
      excluding: id
    )
    replacePosition(
      current,
      status: current.status,
      lanePosition: nil,
      laneOrigin: nil,
      laneSetAt: nil,
      updatedAt: Self.mutationTimestamp
    )
    taskBoardItemsChangeSeq += 1
    return TaskBoardItemPositionMutationResponse(
      snapshot: try taskBoardItemPositionSnapshot(id: id),
      shifted: shifted
    )
  }

  private func requireCurrentPositionSnapshot(_ id: String, _ revision: Int64, _ sequence: Int64)
    throws
  {
    guard taskBoardItemRevisions[id] == revision, taskBoardItemsChangeSeq == sequence else {
      throw HarnessMonitorAPIError.server(code: 409, message: "Task board position is stale")
    }
  }

  private func replacePosition(
    _ item: TaskBoardItem,
    status: TaskBoardStatus,
    lanePosition: UInt32?,
    laneOrigin: TaskBoardLaneOrigin?,
    laneSetAt: String?,
    updatedAt: String
  ) {
    guard let index = taskBoardItems.firstIndex(where: { $0.id == item.id }) else { return }
    taskBoardItems[index] = item.replacingPreviewPosition(
      status: status,
      lanePosition: lanePosition,
      laneOrigin: laneOrigin,
      laneSetAt: laneSetAt,
      updatedAt: updatedAt
    )
    taskBoardItemRevisions[item.id, default: 0] += 1
  }

  private func ensurePositionMutable(_ item: TaskBoardItem) throws {
    guard item.deletedAt == nil else {
      throw HarnessMonitorAPIError.server(
        code: 400, message: "Cannot position a deleted task-board item")
    }
  }

  private func shiftForSet(
    itemID: String,
    source: TaskBoardStatus,
    sourceIndex: UInt32?,
    destination: TaskBoardStatus,
    destinationIndex: UInt32
  ) -> [TaskBoardShiftedItemRevision] {
    let candidates = taskBoardItems.filter { item in
      item.id != itemID && item.deletedAt == nil && item.lanePosition != nil
        && (item.status.canonicalPersistedStatus == source
          || item.status.canonicalPersistedStatus == destination)
    }
    var shifted: [TaskBoardShiftedItemRevision] = []
    for item in candidates {
      guard let index = item.lanePosition else { continue }
      let next: UInt32?
      if source == destination, let sourceIndex, item.status.canonicalPersistedStatus == source {
        if sourceIndex < destinationIndex {
          next = index > sourceIndex && index <= destinationIndex ? index - 1 : nil
        } else if sourceIndex > destinationIndex {
          next = index >= destinationIndex && index < sourceIndex ? index + 1 : nil
        } else {
          next = nil
        }
      } else if item.status.canonicalPersistedStatus == source, let sourceIndex, index > sourceIndex
      {
        next = index - 1
      } else if item.status.canonicalPersistedStatus == destination, index >= destinationIndex {
        next = index + 1
      } else {
        next = nil
      }
      guard let next else { continue }
      replacePosition(
        item,
        status: item.status,
        lanePosition: next,
        laneOrigin: item.laneOrigin,
        laneSetAt: item.laneSetAt,
        updatedAt: item.updatedAt
      )
      shifted.append(
        TaskBoardShiftedItemRevision(
          itemId: item.id,
          itemRevision: taskBoardItemRevisions[item.id] ?? 1
        )
      )
    }
    return shifted
  }

  private func shiftLaterAnchors(
    in status: TaskBoardStatus,
    after index: UInt32,
    excluding itemID: String
  ) -> [TaskBoardShiftedItemRevision] {
    taskBoardItems.compactMap { item in
      guard item.id != itemID, item.deletedAt == nil,
        item.status.canonicalPersistedStatus == status,
        let lanePosition = item.lanePosition, lanePosition > index
      else { return nil }
      replacePosition(
        item,
        status: item.status,
        lanePosition: lanePosition - 1,
        laneOrigin: item.laneOrigin,
        laneSetAt: item.laneSetAt,
        updatedAt: item.updatedAt
      )
      return TaskBoardShiftedItemRevision(
        itemId: item.id, itemRevision: taskBoardItemRevisions[item.id] ?? 1)
    }
  }

  private func taskBoardPositionUnavailable() -> HarnessMonitorAPIError {
    HarnessMonitorAPIError.server(code: 404, message: "Task board item unavailable")
  }

}

extension TaskBoardItem {
  func replacingPreviewPosition(
    status: TaskBoardStatus,
    lanePosition: UInt32?,
    laneOrigin: TaskBoardLaneOrigin?,
    laneSetAt: String?,
    updatedAt: String
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: schemaVersion, id: id, title: title, body: body, status: status,
      priority: priority, tags: tags, projectId: projectId,
      executionRepository: executionRepository,
      targetProjectTypes: targetProjectTypes, agentMode: agentMode, kind: kind,
      externalRefs: externalRefs, importedFromProvider: importedFromProvider, planning: planning,
      workflow: workflow, sessionId: sessionId, workItemId: workItemId, usage: usage,
      parentItemId: parentItemId, childOrder: childOrder, lanePosition: lanePosition,
      laneOrigin: laneOrigin,
      laneSetAt: laneSetAt,
      createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt
    )
  }
}
