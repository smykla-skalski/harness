import HarnessMonitorKit
import SwiftUI

extension TaskBoardOverviewView {
  var orderedSelectedCardIDs: [TaskBoardCardID] {
    selectionModelValue.orderedSelectedIDs
  }

  /// The single API card currently being dragged. Exact lane positioning is a
  /// single-card operation; multi-card and inbox drags keep status-only moves.
  var reorderDraggedItemValue: TaskBoardCardDragItem? {
    guard
      draggedCardIDsValue.count == 1,
      case .api(let itemID) = draggedCardIDsValue[0],
      let item = currentPresentation.taskBoardItem(id: itemID)
    else {
      return nil
    }
    return .api(itemID: item.id, status: item.status, kind: item.kind)
  }

  func cardDragPayloads(
    _ cardIDs: [TaskBoardCardID]
  ) -> [TaskBoardCardDragPayload] {
    let payloads = cardIDs.compactMap(cardDragItem).map(TaskBoardCardDragPayload.init(item:))
    traceTaskBoardCardDrag(
      "payloads requested=\(cardIDs.count) produced=\(payloads.count)"
    )
    return payloads
  }

  func cardDropPlan(
    _ cardIDs: [TaskBoardCardID],
    to lane: TaskBoardInboxLane
  ) -> TaskBoardCardDropPlan? {
    TaskBoardCardDropPlan.resolve(cardDragPayloads(cardIDs), to: lane)
  }

  func updateCardDragSession(_ session: DragSession) {
    if case .active = session.phase {
      TaskBoardCardDragDiagnostics.recordActiveUpdate()
    }
    if taskBoardCardDragSessionShouldCommitGap(for: session.phase) {
      _ = commitGapDropAtPlaceholderIfNeeded(reason: "drag-session-ended")
    }
    switch taskBoardCardDragSessionDecision(
      for: session.phase,
      isActionInFlight: isActionInFlight
    ) {
    case .processInitial:
      TaskBoardCardDragDiagnostics.begin()
      traceTaskBoardCardDrag("session phase=initial")
      updateInitialCardDrag(session)
    case .clear:
      if case .ended = session.phase {
        TaskBoardCardDragDiagnostics.finish()
      }
      traceTaskBoardCardDrag("session phase=\(taskBoardCardDragPhaseName(session.phase))")
      clearTransientCardDragState()
    case .ignore:
      break
    }
  }

  private func updateInitialCardDrag(_ session: DragSession) {
    let draggedIDs = session.draggedItemIDs(for: TaskBoardCardID.self)
    traceTaskBoardCardDrag(
      "session dragged-ids=\(draggedIDs.map { String(describing: $0) }.joined(separator: ","))"
    )
    guard !draggedIDs.isEmpty else {
      return
    }
    // Starting a drag moves the focus ring to the card, same as clicking it. Preserves an
    // existing multi-selection: the whole selection travels, so the sets match and this no-ops.
    selectionModelValue.selectForDrag(draggedIDs)
    resetDropCommit()
    updateDraggedCardIDs(draggedIDs)
    nativeListCoordinatorValue.beginDrag()
    guard beginCardGap(draggedIDs: draggedIDs) else {
      clearTransientCardDragState()
      return
    }
  }

  /// Start the custom insertion gap, but only for a single API card — the exact-position
  /// drop. Multi-card, inbox, and status drags keep the lane highlight and no gap.
  private func beginCardGap(draggedIDs: [TaskBoardCardID]) -> Bool {
    guard draggedIDs.count == 1, case .api(let itemID) = draggedIDs[0] else { return true }
    var sourceLane: TaskBoardInboxLane?
    var sourceIndex = 0
    var draggedItem: TaskBoardItem?
    for lane in TaskBoardInboxLane.allCases {
      let items = currentPresentation.apiItems(in: lane)
      if let index = items.firstIndex(where: { $0.id == itemID }) {
        sourceLane = lane
        sourceIndex = index
        draggedItem = items[index]
        break
      }
    }
    guard let source = sourceLane, let item = draggedItem else { return false }
    var rowInfo: [TaskBoardInboxLane: TaskBoardLaneAPIRowInfo] = [:]
    for lane in TaskBoardInboxLane.allCases {
      rowInfo[lane] = TaskBoardLaneAPIRowInfo(
        firstRow: decisions(in: lane).count,
        count: currentPresentation.apiItems(in: lane).count
      )
    }
    cardGapModelValue.coordinator = nativeListCoordinatorValue
    cardGapModelValue.onDragReleased = {
      // SwiftUI's List sometimes ends an otherwise valid drag as `.cancel` after the
      // board remounts. The pointer tracker still proves the exact target is under the
      // mouse, so use that placeholder as the fallback destination.
      if !commitGapDropAtPlaceholderIfNeeded(reason: "mouse-release-fallback") {
        clearTransientCardDragState()
      }
    }
    cardGapModelValue.begin(
      cardID: draggedIDs[0],
      item: item,
      context: TaskBoardCardGapModel.BeginContext(
        sourceLane: source,
        sourceAPIIndex: sourceIndex,
        // Include the source lane so a same-lane reorder shows the gap and lands where the
        // placeholder is, instead of falling back to the List's native offset.
        candidateLanes: dropCandidateLanesValue.union([source]),
        rowInfo: rowInfo
      )
    )
    return true
  }

  private func updateDraggedCardIDs(_ cardIDs: [TaskBoardCardID]) {
    var candidates: Set<TaskBoardInboxLane> =
      Set(TaskBoardInboxLane.allCases.filter { cardDropPlan(cardIDs, to: $0) != nil })
    // A single API card can also reorder within its source lane. Advertising that lane
    // as a move destination lets AppKit report `.move`, so `.forbidden` remains a real
    // cancellation instead of doubling as the same-lane commit signal.
    if cardIDs.count == 1,
      case .api(let itemID) = cardIDs[0],
      let item = currentPresentation.taskBoardItem(id: itemID),
      let sourceLane = TaskBoardInboxLane(taskBoardItem: item)
    {
      candidates.insert(sourceLane)
    }
    cardDragRuntimeValue.begin(cardIDs: cardIDs, candidateLanes: candidates)
    traceTaskBoardCardDrag(
      "candidate-lanes ids=\(cardIDs.count) lanes="
        + TaskBoardInboxLane.allCases
        .filter(candidates.contains)
        .map(\.rawValue)
        .joined(separator: ",")
    )
  }

  /// On release, land the dragged card where the placeholder is — even when the release
  /// is outside any lane's drop target (above the columns, in a margin). Without this an
  /// off-lane release is a no-op and the card snaps back to its original position. The
  /// didCommitDrop guard means it never double-commits with the lane / fallback drop.
  @discardableResult
  private func commitGapDropAtPlaceholderIfNeeded(reason: String) -> Bool {
    guard !didCommitDropValue else {
      traceTaskBoardCardDrag("placeholder-commit skipped reason=\(reason) already-committed")
      return false
    }
    guard let target = cardGapModelValue.target,
      let cardID = cardGapModelValue.draggedCardID
    else {
      traceTaskBoardCardDrag("placeholder-commit skipped reason=\(reason) no-target")
      return false
    }
    // Only commit if the pointer still confirms the target's list. Over a collapsed
    // lane (no list) or above the lists the target is stale/sticky — let the lane's
    // own fallback drop handle it instead of landing on the wrong lane.
    guard cardGapModelValue.targetIsUnderPointer else {
      traceTaskBoardCardDrag(
        "placeholder-commit skipped reason=\(reason) lane=\(target.lane.rawValue) off-target"
      )
      return false
    }
    let payloads = cardDragPayloads([cardID])
    let offset = cardGapModelValue.insertionOffset(for: target.lane) ?? 0
    traceTaskBoardCardDrag(
      "placeholder-commit reason=\(reason) lane=\(target.lane.rawValue) offset=\(offset)"
    )
    return handleLaneDrop(payloads, to: target.lane, insertionOffset: offset)
  }

  func clearTransientCardDragState() {
    TaskBoardCardDragDiagnostics.finish()
    nativeListCoordinatorValue.finishDrag()
    cardGapModelValue.end()
    guard !draggedCardIDsValue.isEmpty || !dropCandidateLanesValue.isEmpty else {
      return
    }
    traceTaskBoardCardDrag("clearing-transient-drag-state")
    cardDragRuntimeValue.clear()
  }

  @discardableResult
  func cancelActiveCardDrag() -> Bool {
    guard cardDragRuntimeValue.isActive || cardGapModelValue.isActive else {
      return false
    }
    traceTaskBoardCardDrag("cancel-active-drag")
    clearTransientCardDragState()
    return true
  }

  private func cardDragItem(_ cardID: TaskBoardCardID) -> TaskBoardCardDragItem? {
    switch cardID {
    case .api(let itemID):
      guard let item = currentPresentation.taskBoardItem(id: itemID) else {
        return nil
      }
      return .api(itemID: item.id, status: item.status, kind: item.kind)
    case .inbox(let sessionID, let taskID):
      guard
        let item = currentPresentation.inboxItem(id: cardID)
      else {
        return nil
      }
      return .inbox(
        sessionID: sessionID,
        taskID: taskID,
        status: item.task.status,
        sourceLaneRawValue: item.lane.rawValue
      )
    }
  }
}

private func taskBoardCardDragPhaseName(_ phase: DragSession.Phase) -> String {
  switch phase {
  case .initial:
    "initial"
  case .active:
    "active"
  case .ended(let operation):
    "ended-\(String(describing: operation))"
  case .dataTransferCompleted:
    "data-transfer-completed"
  @unknown default:
    "unknown"
  }
}

func taskBoardDropSessionPhaseName(_ phase: DropSession.Phase) -> String {
  switch phase {
  case .entering:
    "entering"
  case .active:
    "active"
  case .exiting:
    "exiting"
  case .ended(let operation):
    "ended-\(taskBoardDropOperationName(operation))"
  case .dataTransferCompleted:
    "data-transfer-completed"
  @unknown default:
    "unknown"
  }
}

private func taskBoardDropOperationName(_ operation: DropOperation) -> String {
  switch operation {
  case .cancel:
    "cancel"
  case .forbidden:
    "forbidden"
  case .copy:
    "copy"
  case .move:
    "move"
  case .delete:
    "delete"
  case .alias:
    "alias"
  @unknown default:
    "unknown"
  }
}
