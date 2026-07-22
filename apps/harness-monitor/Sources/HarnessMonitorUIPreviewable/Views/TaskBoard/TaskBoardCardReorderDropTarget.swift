import HarnessMonitorKit
import SwiftUI

/// Per-card drop target for same-lane reordering. Attached only to the row of
/// the lane a single `.api` card is currently being dragged from - `isEnabled`
/// is false everywhere else, so cross-lane drops keep landing on the column's
/// own `.dropDestination` untouched.
///
/// `DropSession.location`/`.size` here are local to this one row, so "which
/// half of the card" needs no shared coordinate space or hover state that a
/// native drag session would otherwise freeze.
struct TaskBoardCardReorderDropTarget: ViewModifier {
  let hoveredItemID: String
  let lane: TaskBoardInboxLane
  let apiItems: [TaskBoardItem]
  let draggedItemID: String?
  let isEnabled: Bool
  let actions: TaskBoardOverviewActions
  @Binding var insertionHint: TaskBoardCardReorderInsertionHint?

  func body(content: Content) -> some View {
    content
      .dropDestination(for: TaskBoardCardDragPayload.self, isEnabled: isEnabled) { _, session in
        defer { clearInsertionHint() }
        guard let draggedItemID else { return }
        guard
          let plan = TaskBoardCardReorderPlan.resolve(
            draggedItemID: draggedItemID,
            lane: lane,
            apiItems: apiItems,
            hoveredItemID: hoveredItemID,
            insertAfterHovered: insertsAfter(session)
          )
        else {
          return
        }
        actions.reorderTaskBoardItem(plan)
      }
      .dropConfiguration { _ in
        DropConfiguration(operation: isEnabled ? .move : .forbidden)
      }
      .onDropSessionUpdated { session in
        switch session.phase {
        case .entering, .active:
          insertionHint = TaskBoardCardReorderInsertionHint(
            itemID: hoveredItemID,
            insertAfter: insertsAfter(session)
          )
        case .exiting, .ended, .dataTransferCompleted:
          clearInsertionHint()
        @unknown default:
          clearInsertionHint()
        }
      }
  }

  private func insertsAfter(_ session: DropSession) -> Bool {
    session.size.height > 0 && session.location.y >= session.size.height / 2
  }

  private func clearInsertionHint() {
    guard insertionHint?.itemID == hoveredItemID else { return }
    insertionHint = nil
  }
}

extension View {
  /// Thin insertion-line indicator shown on whichever card edge the dragged
  /// card would land against, matching `TaskBoardCardReorderPlan`'s own
  /// before/after semantics so the line never lies about where a drop lands.
  func taskBoardCardReorderInsertionOverlay(
    hint: TaskBoardCardReorderInsertionHint?,
    itemID: String
  ) -> some View {
    let isActive = hint?.itemID == itemID
    return overlay(alignment: hint?.insertAfter == true ? .bottom : .top) {
      if isActive {
        Rectangle()
          .fill(HarnessMonitorTheme.accent)
          .frame(height: 2)
          .accessibilityHidden(true)
      }
    }
  }

  func taskBoardCardReorderDropTarget(
    hoveredItemID: String,
    lane: TaskBoardInboxLane,
    apiItems: [TaskBoardItem],
    draggedItemID: String?,
    isEnabled: Bool,
    actions: TaskBoardOverviewActions,
    insertionHint: Binding<TaskBoardCardReorderInsertionHint?>
  ) -> some View {
    modifier(
      TaskBoardCardReorderDropTarget(
        hoveredItemID: hoveredItemID,
        lane: lane,
        apiItems: apiItems,
        draggedItemID: draggedItemID,
        isEnabled: isEnabled,
        actions: actions,
        insertionHint: insertionHint
      )
    )
  }
}
