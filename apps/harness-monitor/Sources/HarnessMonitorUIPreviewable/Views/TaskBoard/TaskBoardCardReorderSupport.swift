import HarnessMonitorKit

enum TaskBoardCardReorderDropDecision: Equatable {
  case proceed(TaskBoardCardReorderPlan)
  case noChange
  case reject(String)
}

/// The dragged card, its lane, the lane's current ordering, and the card it
/// hovers over - everything a reorder decision needs to know about the board,
/// as opposed to `isEnabled`/`insertAfterHovered`, which describe the drop
/// gesture itself.
struct TaskBoardCardReorderDropContext {
  let draggedItemID: String?
  let lane: TaskBoardInboxLane
  let apiItems: [TaskBoardItem]
  let hoveredItemID: String
}

/// Same-lane reorder plan: a card dropped on another card within its own lane.
/// The daemon's lane-position contract (`place_in_destination` in
/// `lane_order.rs`) removes the dragged item from its current slot first, then
/// inserts it at `lanePosition` among the *remaining* siblings, shifting
/// anyone at or after that slot right by one. `resolve` mirrors that exactly
/// so the client never sends a slot the daemon would reinterpret differently.
struct TaskBoardCardReorderPlan: Equatable {
  let itemID: String
  let status: TaskBoardStatus
  let placement: TaskBoardRelativeLanePlacement

  static func resolve(
    _ context: TaskBoardCardReorderDropContext,
    insertAfterHovered: Bool
  ) -> Self? {
    guard
      case .proceed(let plan) = dropDecision(
        isEnabled: true,
        context,
        insertAfterHovered: insertAfterHovered
      )
    else {
      return nil
    }
    return plan
  }

  static func dropDecision(
    isEnabled: Bool,
    _ context: TaskBoardCardReorderDropContext,
    insertAfterHovered: Bool
  ) -> TaskBoardCardReorderDropDecision {
    guard isEnabled else {
      return .reject("Cannot reorder task: it can no longer move within this lane")
    }
    let lane = context.lane
    let apiItems = context.apiItems
    let hoveredItemID = context.hoveredItemID
    guard
      lane != .umbrella,
      let draggedItemID = context.draggedItemID,
      let draggedIndex = apiItems.firstIndex(where: { $0.id == draggedItemID }),
      let hoveredIndex = apiItems.firstIndex(where: { $0.id == hoveredItemID }),
      TaskBoardInboxLane(taskBoardItem: apiItems[draggedIndex]) == lane,
      TaskBoardInboxLane(taskBoardItem: apiItems[hoveredIndex]) == lane
    else {
      return .reject("Cannot reorder task: the board changed before the drop completed")
    }
    let placement = TaskBoardRelativeLanePlacement(
      anchorItemID: hoveredItemID,
      edge: insertAfterHovered ? .after : .before
    )
    guard
      placement.resolvePosition(
        itemID: draggedItemID,
        orderedItemIDs: apiItems.map(\.id)
      ) != nil
    else {
      return .noChange
    }
    return .proceed(
      Self(
        itemID: draggedItemID,
        status: apiItems[draggedIndex].status,
        placement: placement
      )
    )
  }
}

/// Which side of a hovered card the pointer is over, used only to render the
/// insertion line; the relative placement above is resolved against a fresh
/// daemon snapshot at delivery time.
struct TaskBoardCardReorderInsertionHint: Equatable {
  let itemID: String
  let insertAfter: Bool
}
