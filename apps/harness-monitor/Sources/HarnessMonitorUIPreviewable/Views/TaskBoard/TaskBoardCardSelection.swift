import SwiftUI

enum TaskBoardCardID: Codable, Hashable, Sendable {
  case api(String)
  case inbox(sessionID: String, taskID: String)
}

struct TaskBoardCardSelectionState: Equatable {
  private(set) var selectedIDs: Set<TaskBoardCardID>
  private(set) var anchorID: TaskBoardCardID?

  init(
    selectedIDs: Set<TaskBoardCardID> = [],
    anchorID: TaskBoardCardID? = nil
  ) {
    self.selectedIDs = selectedIDs
    self.anchorID = anchorID
  }

  func selecting(
    _ cardID: TaskBoardCardID,
    orderedVisibleIDs: [TaskBoardCardID],
    modifiers: EventModifiers
  ) -> Self {
    if !modifiers.contains(.command), !modifiers.contains(.shift) {
      return Self(selectedIDs: [cardID], anchorID: cardID)
    }
    let change = SessionSidebarMultiSelect.resolve(
      rowID: cardID,
      orderedVisibleIDs: orderedVisibleIDs,
      selectedIDs: selectedIDs,
      anchorID: anchorID,
      modifiers: modifiers
    )
    return Self(selectedIDs: change.selectedIDs, anchorID: change.anchorID)
  }

  func selectingForDrag(_ draggedIDs: [TaskBoardCardID]) -> Self {
    guard let first = draggedIDs.first else {
      return self
    }
    let draggedIDSet = Set(draggedIDs)
    guard draggedIDSet != selectedIDs else {
      return self
    }
    return Self(selectedIDs: draggedIDSet, anchorID: first)
  }

  func selectingForContextMenu(_ menuIDs: [TaskBoardCardID]) -> Self {
    guard let first = menuIDs.first else {
      return self
    }
    let menuIDSet = Set(menuIDs)
    guard menuIDSet != selectedIDs else {
      return self
    }
    return Self(selectedIDs: menuIDSet, anchorID: first)
  }

  func pruning(orderedVisibleIDs: [TaskBoardCardID]) -> Self {
    let visibleIDs = Set(orderedVisibleIDs)
    let prunedSelection = selectedIDs.intersection(visibleIDs)
    let repairedAnchor =
      if let anchorID, prunedSelection.contains(anchorID) {
        anchorID
      } else {
        orderedVisibleIDs.first { prunedSelection.contains($0) }
      }
    return Self(selectedIDs: prunedSelection, anchorID: repairedAnchor)
  }

  func orderedSelectedIDs(in orderedVisibleIDs: [TaskBoardCardID]) -> [TaskBoardCardID] {
    orderedVisibleIDs.filter(selectedIDs.contains)
  }
}
