import HarnessMonitorKit

enum TaskBoardCardReorderDropDecision: Equatable {
  case proceed(TaskBoardCardReorderPlan)
  case noChange
  case reject(String)
}

struct TaskBoardCardReorderDropContext {
  let draggedItem: TaskBoardCardDragItem?
  let lane: TaskBoardInboxLane
  let apiItems: [TaskBoardItem]
  let insertionOffset: Int
}

/// One atomic task-board position change. Source status is captured at drag
/// start; SwiftUI supplies the insertion offset from the destination lane's
/// dynamic content.
struct TaskBoardCardReorderPlan: Equatable {
  let itemID: String
  let sourceStatus: TaskBoardStatus
  let destinationStatus: TaskBoardStatus
  let placement: TaskBoardLanePlacement

  static func resolve(_ context: TaskBoardCardReorderDropContext) -> Self? {
    guard case .proceed(let plan) = dropDecision(isEnabled: true, context) else {
      return nil
    }
    return plan
  }

  static func dropDecision(
    isEnabled: Bool,
    _ context: TaskBoardCardReorderDropContext
  ) -> TaskBoardCardReorderDropDecision {
    guard isEnabled else {
      return .reject("Cannot position task: an action is already in progress")
    }
    guard
      context.lane != .umbrella,
      let destinationStatus = context.lane.taskBoardDropStatus,
      case .api(let itemID, let sourceStatus, let kind) = context.draggedItem,
      kind != .umbrella
    else {
      return .reject("Cannot position task: it can no longer move to this lane")
    }
    guard
      context.apiItems.allSatisfy({
        $0.kind != .umbrella && TaskBoardInboxLane(taskBoardItem: $0) == context.lane
      }),
      (0...context.apiItems.count).contains(context.insertionOffset)
    else {
      return .reject("Cannot position task: the board changed before the drop completed")
    }
    let sourceLane = TaskBoardInboxLane(status: sourceStatus, kind: kind)
    let sourceIndex = context.apiItems.firstIndex(where: { $0.id == itemID })
    if sourceLane == context.lane {
      guard let sourceIndex else {
        return .reject("Cannot position task: the board changed before the drop completed")
      }
      if context.insertionOffset == sourceIndex || context.insertionOffset == sourceIndex + 1 {
        return .noChange
      }
    } else if sourceIndex != nil {
      return .reject("Cannot position task: the board changed before the drop completed")
    }
    let placement = placement(context)
    return .proceed(
      Self(
        itemID: itemID,
        sourceStatus: sourceStatus,
        destinationStatus: destinationStatus,
        placement: placement
      )
    )
  }

  private static func placement(
    _ context: TaskBoardCardReorderDropContext
  ) -> TaskBoardLanePlacement {
    let offset = context.insertionOffset
    if offset == 0 {
      return .first
    }
    if offset == context.apiItems.count {
      return .last
    }
    return .relative(
      TaskBoardRelativeLanePlacement(
        anchorItemID: context.apiItems[offset].id,
        edge: .before
      )
    )
  }
}
