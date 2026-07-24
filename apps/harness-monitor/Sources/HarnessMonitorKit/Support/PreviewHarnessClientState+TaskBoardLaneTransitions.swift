import Foundation

extension PreviewHarnessClientState {
  func replaceTaskBoardItemWithLaneTransition(_ replacement: TaskBoardItem) -> TaskBoardItem {
    guard let targetIndex = taskBoardItems.firstIndex(where: { $0.id == replacement.id }) else {
      taskBoardItems.append(replacement)
      taskBoardItemRevisions[replacement.id] = 1
      taskBoardItemsChangeSeq += 1
      return replacement
    }

    let previous = taskBoardItems[targetIndex]
    var updated = replacement.replacingPreviewPosition(
      status: replacement.status.canonicalPersistedStatus,
      lanePosition: replacement.lanePosition,
      laneOrigin: replacement.laneOrigin,
      laneSetAt: replacement.laneSetAt,
      updatedAt: replacement.updatedAt
    )
    let source = previous.deletedAt == nil ? previous.status.canonicalPersistedStatus : nil
    let destination = updated.deletedAt == nil ? updated.status.canonicalPersistedStatus : nil
    let genericCrossLaneAnchor =
      source != destination
      && previous.lanePosition != nil
      && updated.lanePosition == previous.lanePosition
      && updated.laneOrigin == previous.laneOrigin
      && updated.laneSetAt == previous.laneSetAt

    if let source, previous.deletedAt == nil,
      source != destination || previous.lanePosition != updated.lanePosition,
      let sourcePosition = previous.lanePosition
        ?? materializedLanePosition(for: previous, in: source)
    {
      compactPreviewLane(status: source, after: sourcePosition, excluding: previous.id)
    }

    let unchangedSameLanePosition =
      source == destination
      && previous.lanePosition == updated.lanePosition
    if let destination, updated.deletedAt == nil, !unchangedSameLanePosition,
      let requestedPosition = updated.lanePosition
    {
      let destinationCount = UInt32(
        clamping: taskBoardItems.count { item in
          item.id != previous.id
            && item.deletedAt == nil
            && item.status.canonicalPersistedStatus == destination
        })
      let lanePosition =
        genericCrossLaneAnchor
        ? min(requestedPosition, destinationCount)
        : requestedPosition
      updated = updated.replacingPreviewPosition(
        status: destination,
        lanePosition: lanePosition,
        laneOrigin: updated.laneOrigin,
        laneSetAt: updated.laneSetAt,
        updatedAt: updated.updatedAt
      )
      openPreviewLaneSlot(status: destination, at: lanePosition, excluding: previous.id)
    }

    taskBoardItems[targetIndex] = updated
    taskBoardItemRevisions[updated.id, default: 0] += 1
    taskBoardItemsChangeSeq += 1
    return updated
  }

  func deleteTaskBoardItemWithLaneTransition(id: String) throws -> TaskBoardItem {
    guard let targetIndex = taskBoardItems.firstIndex(where: { $0.id == id }) else {
      throw taskBoardItemUnavailable()
    }
    let deleted = taskBoardItems[targetIndex]
    if deleted.deletedAt == nil,
      let sourcePosition = deleted.lanePosition
        ?? materializedLanePosition(for: deleted, in: deleted.status.canonicalPersistedStatus)
    {
      compactPreviewLane(
        status: deleted.status.canonicalPersistedStatus,
        after: sourcePosition,
        excluding: deleted.id
      )
    }
    taskBoardItems.remove(at: targetIndex)
    taskBoardItemRevisions.removeValue(forKey: id)
    taskBoardTriageDecisionsByItemID.removeValue(forKey: id)
    taskBoardTriageOverrideByItemID.removeValue(forKey: id)
    taskBoardItemsChangeSeq += 1
    return deleted
  }

  private func compactPreviewLane(
    status: TaskBoardStatus, after position: UInt32, excluding id: String
  ) {
    for index in taskBoardItems.indices {
      let item = taskBoardItems[index]
      guard item.id != id, item.deletedAt == nil,
        item.status.canonicalPersistedStatus == status,
        let lanePosition = item.lanePosition, lanePosition > position
      else { continue }
      taskBoardItems[index] = item.replacingPreviewPosition(
        status: item.status,
        lanePosition: lanePosition - 1,
        laneOrigin: item.laneOrigin,
        laneSetAt: item.laneSetAt,
        updatedAt: item.updatedAt
      )
      taskBoardItemRevisions[item.id, default: 0] += 1
    }
  }

  private func openPreviewLaneSlot(
    status: TaskBoardStatus, at position: UInt32, excluding id: String
  ) {
    for index in taskBoardItems.indices {
      let item = taskBoardItems[index]
      guard item.id != id, item.deletedAt == nil,
        item.status.canonicalPersistedStatus == status,
        let lanePosition = item.lanePosition, lanePosition >= position
      else { continue }
      taskBoardItems[index] = item.replacingPreviewPosition(
        status: item.status,
        lanePosition: lanePosition + 1,
        laneOrigin: item.laneOrigin,
        laneSetAt: item.laneSetAt,
        updatedAt: item.updatedAt
      )
      taskBoardItemRevisions[item.id, default: 0] += 1
    }
  }
}
