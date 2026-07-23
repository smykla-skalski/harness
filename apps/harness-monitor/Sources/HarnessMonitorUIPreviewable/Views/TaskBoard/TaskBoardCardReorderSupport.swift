import HarnessMonitorKit

enum TaskBoardCardReorderDropDecision: Equatable {
  case proceed(TaskBoardCardReorderPlan)
  case noChange
  case reject(String)
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
    draggedItemID: String,
    lane: TaskBoardInboxLane,
    apiItems: [TaskBoardItem],
    hoveredItemID: String,
    insertAfterHovered: Bool
  ) -> Self? {
    guard
      case .proceed(let plan) = dropDecision(
        isEnabled: true,
        draggedItemID: draggedItemID,
        lane: lane,
        apiItems: apiItems,
        hoveredItemID: hoveredItemID,
        insertAfterHovered: insertAfterHovered
      )
    else {
      return nil
    }
    return plan
  }

  static func dropDecision(
    isEnabled: Bool,
    draggedItemID: String?,
    lane: TaskBoardInboxLane,
    apiItems: [TaskBoardItem],
    hoveredItemID: String,
    insertAfterHovered: Bool
  ) -> TaskBoardCardReorderDropDecision {
    guard isEnabled else {
      return .reject("Cannot reorder task: it can no longer move within this lane")
    }
    guard
      lane != .umbrella,
      let draggedItemID,
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
