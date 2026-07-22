import HarnessMonitorKit

/// Same-lane reorder plan: a card dropped on another card within its own lane.
/// The daemon's lane-position contract (`place_in_destination` in
/// `lane_order.rs`) removes the dragged item from its current slot first, then
/// inserts it at `lanePosition` among the *remaining* siblings, shifting
/// anyone at or after that slot right by one. `resolve` mirrors that exactly
/// so the client never sends a slot the daemon would reinterpret differently.
struct TaskBoardCardReorderPlan: Equatable {
  let itemID: String
  let status: TaskBoardStatus
  let lanePosition: UInt32

  static func resolve(
    draggedItemID: String,
    lane: TaskBoardInboxLane,
    apiItems: [TaskBoardItem],
    hoveredItemID: String,
    insertAfterHovered: Bool
  ) -> Self? {
    guard
      let draggedIndex = apiItems.firstIndex(where: { $0.id == draggedItemID }),
      let hoveredIndex = apiItems.firstIndex(where: { $0.id == hoveredItemID }),
      TaskBoardInboxLane(taskBoardItem: apiItems[draggedIndex]) == lane
    else {
      return nil
    }
    let rawTarget = insertAfterHovered ? hoveredIndex + 1 : hoveredIndex
    // The dragged item vacates its own slot before the insert, so every raw
    // target past it shifts left by one to land among the remaining siblings.
    let adjustedTarget = draggedIndex < rawTarget ? rawTarget - 1 : rawTarget
    let clampedTarget = max(0, min(adjustedTarget, apiItems.count - 1))
    guard clampedTarget != draggedIndex, let lanePosition = UInt32(exactly: clampedTarget) else {
      // Either a no-op drop (same slot it already occupies) or an
      // out-of-range index a stale array shouldn't produce; both skip.
      return nil
    }
    return Self(
      itemID: draggedItemID,
      status: apiItems[draggedIndex].status,
      lanePosition: lanePosition
    )
  }
}

/// Which side of a hovered card the pointer is over, used only to render the
/// insertion line; the drop math above is computed independently from the
/// live `DropSession` at delivery time.
struct TaskBoardCardReorderInsertionHint: Equatable {
  let itemID: String
  let insertAfter: Bool
}
