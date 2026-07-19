import HarnessMonitorKit
import Observation
import SwiftUI

/// Rows hold this by reference instead of `onSelect`/`onOpenItem` closures,
/// so row props stay structurally equatable.
@MainActor
@Observable
final class TaskBoardCardSelectionModel {
  private(set) var multiSelection = TaskBoardCardSelectionState()
  private(set) var orderedVisibleIDs: [TaskBoardCardID] = []
  var selectedItemID: String?
  var isCreatingItem = false

  var selectedIDs: Set<TaskBoardCardID> {
    multiSelection.selectedIDs
  }

  var orderedSelectedIDs: [TaskBoardCardID] {
    multiSelection.orderedSelectedIDs(in: orderedVisibleIDs)
  }

  func select(_ cardID: TaskBoardCardID, modifiers: EventModifiers) {
    let next = multiSelection.selecting(
      cardID,
      orderedVisibleIDs: orderedVisibleIDs,
      modifiers: modifiers
    )
    if multiSelection != next {
      multiSelection = next
    }
  }

  func selectForDrag(_ draggedIDs: [TaskBoardCardID]) {
    let next = multiSelection.selectingForDrag(draggedIDs)
    if multiSelection != next {
      multiSelection = next
    }
  }

  func primeForContextMenu(_ menuIDs: [TaskBoardCardID]) {
    let next = multiSelection.selectingForContextMenu(menuIDs)
    if multiSelection != next {
      multiSelection = next
    }
  }

  /// Call from `.task(id:)`, never from `body`.
  func updateVisibleIDs(_ ids: [TaskBoardCardID]) {
    guard orderedVisibleIDs != ids else { return }
    orderedVisibleIDs = ids
    let pruned = multiSelection.pruning(orderedVisibleIDs: ids)
    if multiSelection != pruned {
      multiSelection = pruned
    }
  }

  func openAPIItem(_ item: TaskBoardItem, actions: TaskBoardOverviewActions) {
    switch TaskBoardOverviewItemBehavior.selectionAction(for: item) {
    case .openLinkedTask:
      isCreatingItem = false
      selectedItemID = nil
      actions.openTaskBoardItem(item)
    case .selectBoardItem:
      isCreatingItem = false
      selectedItemID = item.id
    }
  }

  func beginCreatingItem() {
    selectedItemID = nil
    isCreatingItem = true
  }

  func clearSelectedItem() {
    selectedItemID = nil
    isCreatingItem = false
  }
}
