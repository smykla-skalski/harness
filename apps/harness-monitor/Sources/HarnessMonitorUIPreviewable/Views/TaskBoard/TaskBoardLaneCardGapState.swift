import HarnessMonitorKit
import SwiftUI

struct TaskBoardLaneAPIRowInfo: Equatable {
  var firstRow: Int
  var count: Int
}

func taskBoardCardGapSourceTargetIndex(sourceIndex: Int, sourceCount: Int) -> Int {
  min(max(sourceIndex, 0), max(0, sourceCount - 1))
}

func taskBoardCardGapPointerYInSnapshotSpace(
  pointerY: CGFloat,
  snapshotReferenceY: CGFloat,
  currentReferenceY: CGFloat
) -> CGFloat {
  pointerY - (currentReferenceY - snapshotReferenceY)
}

func taskBoardCardGapInsertionIndex(
  midpoints: [CGFloat],
  currentIndex: Int?,
  pointerY: CGFloat,
  gapHeight: CGFloat
) -> Int {
  let count = midpoints.count
  guard let currentIndex else {
    return midpoints.count { $0 > pointerY }
  }
  var index = min(max(currentIndex, 0), count)
  while index > 0, pointerY > midpoints[index - 1] {
    index -= 1
  }
  while index < count, pointerY < midpoints[index] - gapHeight {
    index += 1
  }
  return index
}

@MainActor
@Observable
final class TaskBoardLaneCardGapState {
  struct Presentation {
    var displayIndex: Int?
    var insertionOffset: Int?
    var gapHeight: CGFloat
    var keepsListVisible: Bool
    var showsMarker: Bool
  }

  private(set) var draggedCardID: TaskBoardCardID?
  private(set) var draggedItem: TaskBoardItem?
  private(set) var displayIndex: Int?
  private(set) var insertionOffset: Int?
  private(set) var gapHeight: CGFloat = 48
  private(set) var keepsListVisible = false
  private(set) var showsMarker = false

  var isActive: Bool { draggedCardID != nil }

  func begin(
    cardID: TaskBoardCardID,
    item: TaskBoardItem,
    presentation: Presentation
  ) {
    displayIndex = presentation.displayIndex
    insertionOffset = presentation.insertionOffset
    gapHeight = presentation.gapHeight
    keepsListVisible = presentation.keepsListVisible
    showsMarker = presentation.showsMarker
    draggedItem = item
    // The ID activates the lane's drag presentation, so publish it last.
    draggedCardID = cardID
  }

  func updateDisplay(
    index: Int?,
    insertionOffset: Int?,
    showsMarker: Bool
  ) {
    if displayIndex != index {
      displayIndex = index
    }
    if self.insertionOffset != insertionOffset {
      self.insertionOffset = insertionOffset
    }
    if self.showsMarker != showsMarker {
      self.showsMarker = showsMarker
    }
  }

  func end() {
    draggedCardID = nil
    draggedItem = nil
    displayIndex = nil
    insertionOffset = nil
    keepsListVisible = false
    showsMarker = false
  }
}

/// Drives the custom insertion gap for a single-API-card drag. macOS 26 has no native
/// cross-lane gap (`.gap` crashes the List bridge and the drop-session callbacks never
/// fire inside a List — see the taskboard-dnd-macos26-recipe memory), so the dragged
/// card is rendered as a placeholder and live-reordered to the drop point. This model
/// owns the pointer targeting: a snapshot of resting API-row midpoints, translated by
