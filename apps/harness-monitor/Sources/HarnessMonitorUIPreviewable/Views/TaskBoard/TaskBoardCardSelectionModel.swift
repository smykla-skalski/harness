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
  /// The one lane whose quick-add field is open, if any.
  private(set) var quickAddLane: TaskBoardInboxLane?

  /// False while a text field the board hosts has the keystrokes. The Edit menu
  /// binds bare Delete, and a menu key equivalent beats a focused field to it,
  /// so a lane composer left out of this gate deletes cards as someone types.
  var acceptsBoardShortcuts: Bool {
    !isCreatingItem && quickAddLane == nil
  }

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
    quickAddLane = nil
    selectedItemID = nil
    isCreatingItem = true
  }

  func clearSelectedItem() {
    selectedItemID = nil
    isCreatingItem = false
  }

  func beginQuickAdd(in lane: TaskBoardInboxLane) {
    guard quickAddLane != lane else { return }
    quickAddLane = lane
  }

  /// Takes the lane so the field that just lost focus cannot close the one that
  /// took it: opening a second lane's field ends the first, in that order.
  func endQuickAdd(in lane: TaskBoardInboxLane) {
    guard quickAddLane == lane else { return }
    quickAddLane = nil
  }
}
