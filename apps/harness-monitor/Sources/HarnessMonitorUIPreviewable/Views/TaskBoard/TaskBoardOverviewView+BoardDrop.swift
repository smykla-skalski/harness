import HarnessMonitorKit
import SwiftUI

enum TaskBoardCardDropGate: Equatable {
  case proceed(TaskBoardCardDropPlan)
  case reject(String)
}

func taskBoardCardDropGate(
  payloads: [TaskBoardCardDragPayload],
  lane: TaskBoardInboxLane,
  isDropEnabled: Bool,
  isDropCandidate: Bool
) -> TaskBoardCardDropGate {
  guard isDropEnabled else {
    return .reject("Cannot move task: an action is already in progress")
  }
  guard isDropCandidate, let plan = TaskBoardCardDropPlan.resolve(payloads, to: lane) else {
    return .reject("Cannot move task: it can no longer move to this lane")
  }
  return .proceed(plan)
}

extension TaskBoardOverviewView {
  func handleLaneDrop(
    _ payloads: [TaskBoardCardDragPayload],
    to lane: TaskBoardInboxLane,
    insertionOffset: Int
  ) -> Bool {
    // The per-row dropDestination and the whole-lane fallback can both fire for one
    // drop; commit only once per drag.
    guard !didCommitDropValue else { return false }
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    return withTransaction(transaction) {
      defer { clearTransientCardDragState() }
      traceTaskBoardCardDrag(
        "delivered lane=\(lane.rawValue) offset=\(insertionOffset) payloads=\(payloads.count)"
      )
      let accepted: Bool
      if let draggedItem = singleAPIDragItem(in: payloads) {
        accepted = handlePositionDrop(
          draggedItem,
          to: lane,
          insertionOffset: insertionOffset
        )
      } else {
        accepted = handleStatusDrop(payloads, to: lane)
      }
      guard accepted else { return false }
      markDropCommitted()
      nativeListCoordinatorValue.prepareForModelMutation()
      return true
    }
  }

  private func handlePositionDrop(
    _ draggedItem: TaskBoardCardDragItem,
    to lane: TaskBoardInboxLane,
    insertionOffset: Int
  ) -> Bool {
    let context = TaskBoardCardReorderDropContext(
      draggedItem: draggedItem,
      lane: lane,
      apiItems: currentPresentation.apiItems(in: lane),
      insertionOffset: insertionOffset
    )
    switch TaskBoardCardReorderPlan.dropDecision(isEnabled: !isActionInFlight, context) {
    case .proceed(let plan):
      beginOptimisticSettleMeasurement()
      traceTaskBoardCardDrag(
        "decision=proceed item=\(plan.itemID) destination=\(plan.destinationStatus.rawValue)"
      )
      guard actions.reorderTaskBoardItem(plan) else {
        cancelOptimisticSettleMeasurement()
        actions.reportDropRejection(
          "Cannot move task: the board changed before the move completed"
        )
        return false
      }
      requestLaneReveal(cardID: draggedItem.id, in: lane, anchor: .minimal)
      applyImmediateTaskBoardPositionProjection()
      return true
    case .noChange:
      traceTaskBoardCardDrag("decision=no-change")
      return true
    case .reject(let reason):
      traceTaskBoardCardDrag("decision=reject reason=\(reason)")
      actions.reportDropRejection(reason)
      return false
    }
  }

  private func handleStatusDrop(
    _ payloads: [TaskBoardCardDragPayload],
    to lane: TaskBoardInboxLane
  ) -> Bool {
    switch taskBoardCardDropGate(
      payloads: payloads,
      lane: lane,
      isDropEnabled: !isActionInFlight,
      isDropCandidate: dropCandidateLanesValue.contains(lane)
    ) {
    case .reject(let reason):
      actions.reportDropRejection(reason)
      return false
    case .proceed(let plan):
      let moved = actions.moveCardsOrReportRejection(
        plan.items,
        to: lane,
        liveInboxItems: liveInboxItemsValue
      )
      if moved, let cardID = payloads.first?.id {
        requestLaneReveal(cardID: cardID, in: lane, anchor: .minimal)
      }
      return moved
    }
  }

  private func singleAPIDragItem(
    in payloads: [TaskBoardCardDragPayload]
  ) -> TaskBoardCardDragItem? {
    var seenIDs: Set<TaskBoardCardID> = []
    let items = payloads.flatMap(\.items).filter { seenIDs.insert($0.id).inserted }
    guard items.count == 1, case .api = items[0] else {
      return nil
    }
    return items[0]
  }
}
