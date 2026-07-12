import HarnessMonitorKit
import SwiftUI

extension TaskBoardOverviewView {
  var orderedSelectedCardIDs: [TaskBoardCardID] {
    cardSelectionValue.orderedSelectedIDs(
      in: currentPresentation.orderedCardIDs
    )
  }

  func selectCard(
    _ cardID: TaskBoardCardID,
    orderedVisibleIDs: [TaskBoardCardID],
    modifiers: EventModifiers
  ) {
    let next = cardSelectionValue.selecting(
      cardID,
      orderedVisibleIDs: orderedVisibleIDs,
      modifiers: modifiers
    )
    if cardSelectionValue != next {
      cardSelectionValue = next
    }
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
    switch session.phase {
    case .initial, .active:
      updateActiveCardDrag(session)
    case .ended, .dataTransferCompleted:
      updateDraggedCardIDs([])
    @unknown default:
      updateDraggedCardIDs([])
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
    let next = cardSelectionValue.selectingForDrag(draggedIDs)
    if cardSelectionValue != next {
      cardSelectionValue = next
    }
  }

  private func updateDraggedCardIDs(_ cardIDs: [TaskBoardCardID]) {
    if draggedCardIDsValue != cardIDs {
      draggedCardIDsValue = cardIDs
    }
  }

  func moveCards(
    _ items: [TaskBoardCardDragItem],
    to lane: TaskBoardInboxLane
  ) -> Bool {
    guard !isActionInFlight else {
      return false
    }
    var taskBoardUpdates: [TaskBoardItemStatusUpdate] = []
    var inboxUpdates: [TaskBoardInboxStatusUpdate] = []
    for item in items {
      guard item.accepts(destination: lane) else {
        return false
      }
      switch item {
      case .api(let itemID, let sourceStatus):
        guard
          onMoveTaskBoardItems != nil,
          let current = currentPresentation.taskBoardItem(id: itemID),
          current.status == sourceStatus
        else {
          return false
        }
        let destinationStatus = lane.taskBoardDropStatus(for: current)
        taskBoardUpdates.append(
          TaskBoardItemStatusUpdate(id: itemID, status: destinationStatus)
        )
      case .inbox(_, _, let sourceStatus, let sourceLaneRawValue):
        guard
          onMoveInboxItems != nil,
          let destinationStatus = lane.taskDropStatus,
          let current = currentPresentation.inboxItem(id: item.id),
          current.task.status == sourceStatus,
          current.lane.rawValue == sourceLaneRawValue
        else {
          return false
        }
        inboxUpdates.append(
          TaskBoardInboxStatusUpdate(
            sessionID: current.session.sessionId,
            taskID: current.task.taskId,
            status: destinationStatus
          )
        )
      }
    }
    guard !taskBoardUpdates.isEmpty || !inboxUpdates.isEmpty else {
      return false
    }
    if !taskBoardUpdates.isEmpty {
      onMoveTaskBoardItems?(taskBoardUpdates)
    }
    if !inboxUpdates.isEmpty {
      onMoveInboxItems?(inboxUpdates)
    }
    return true
  }

  private func cardDragItem(_ cardID: TaskBoardCardID) -> TaskBoardCardDragItem? {
    switch cardID {
    case .api(let itemID):
      guard let item = currentPresentation.taskBoardItem(id: itemID) else {
        return nil
      }
      return .api(itemID: item.id, status: item.status)
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
