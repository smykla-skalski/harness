import HarnessMonitorKit
import SwiftUI

/// Pure routing decision for a drag-session phase update, extracted so it stays testable without
/// a live `TaskBoardOverviewView`. `.ignore` only applies to the active phases - terminal phases
/// (`.ended`/`.dataTransferCompleted`) must always resolve to `.clear` even while an action is in
/// flight, since a drop itself sets `isActionInFlight` before the session delivers `.ended`.
enum TaskBoardCardDragSessionDecision: Equatable {
  case processActive
  case clear
  case ignore
}

func taskBoardCardDragSessionDecision(
  for phase: DragSession.Phase,
  isActionInFlight: Bool
) -> TaskBoardCardDragSessionDecision {
  switch phase {
  case .initial, .active:
    isActionInFlight ? .ignore : .processActive
  case .ended, .dataTransferCompleted:
    .clear
  @unknown default:
    .clear
  }
}

extension TaskBoardOverviewView {
  var orderedSelectedCardIDs: [TaskBoardCardID] {
    selectionModelValue.orderedSelectedIDs
  }

  /// The single `.api` card currently being dragged, or `nil` when nothing is
  /// dragging, more than one card is selected for the drag, or the dragged
  /// card is an inbox item. Same-lane reorder only applies to one task-board
  /// item at a time; every other case keeps the existing cross-lane behavior.
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
    cardIDs.compactMap(cardDragItem).map(TaskBoardCardDragPayload.init(item:))
  }

  func cardDropPlan(
    _ cardIDs: [TaskBoardCardID],
    to lane: TaskBoardInboxLane
  ) -> TaskBoardCardDropPlan? {
    TaskBoardCardDropPlan.resolve(cardDragPayloads(cardIDs), to: lane)
  }

  func updateCardDragSession(_ session: DragSession) {
    switch taskBoardCardDragSessionDecision(
      for: session.phase,
      isActionInFlight: isActionInFlight
    ) {
    case .processActive:
      updateActiveCardDrag(session)
    case .clear:
      updateDraggedCardIDs([])
    case .ignore:
      break
    }
  }

  private func updateActiveCardDrag(_ session: DragSession) {
    let draggedIDs = session.draggedItemIDs(for: TaskBoardCardID.self)
    guard !draggedIDs.isEmpty else {
      return
    }
    updateDraggedCardIDs(draggedIDs)
    guard case .initial = session.phase else {
      return
    }
    selectionModelValue.selectForDrag(draggedIDs)
  }

  private func updateDraggedCardIDs(_ cardIDs: [TaskBoardCardID]) {
    guard draggedCardIDsValue != cardIDs else {
      return
    }
    draggedCardIDsValue = cardIDs
    dropCandidateLanesValue =
      cardIDs.isEmpty
      ? []
      : Set(TaskBoardInboxLane.allCases.filter { cardDropPlan(cardIDs, to: $0) != nil })
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
