import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Task board card selection")
struct TaskBoardCardSelectionTests {
  private let first = TaskBoardCardID.api("task-a")
  private let second = TaskBoardCardID.api("task-b")
  private let third = TaskBoardCardID.inbox(sessionID: "session-a", taskID: "task-c")

  @Test("Plain click replaces selection with an unselected card")
  func plainClickReplacesSelectionWithUnselectedCard() {
    let state = TaskBoardCardSelectionState(selectedIDs: [first, second], anchorID: first)

    let next = state.selecting(
      third,
      orderedVisibleIDs: [first, second, third],
      modifiers: []
    )

    #expect(next.selectedIDs == [third])
    #expect(next.anchorID == third)
  }

  @Test("Plain click collapses a selected group to the clicked card")
  func plainClickCollapsesSelectedGroup() {
    let state = TaskBoardCardSelectionState(selectedIDs: [first, second], anchorID: first)

    let next = state.selecting(
      second,
      orderedVisibleIDs: [first, second, third],
      modifiers: []
    )

    #expect(next.selectedIDs == [second])
    #expect(next.anchorID == second)
  }

  @Test("Starting a group drag preserves every selected card")
  func startingGroupDragPreservesEverySelectedCard() {
    let state = TaskBoardCardSelectionState(selectedIDs: [first, second], anchorID: first)

    let next = state.selectingForDrag([first, second])

    #expect(next == state)
  }

  @Test("Command click toggles cards across lanes")
  func commandClickTogglesCardsAcrossLanes() {
    let state = TaskBoardCardSelectionState(selectedIDs: [first], anchorID: first)

    let selected = state.selecting(
      third,
      orderedVisibleIDs: [third],
      modifiers: .command
    )
    let deselected = selected.selecting(
      first,
      orderedVisibleIDs: [first, second],
      modifiers: .command
    )

    #expect(selected.selectedIDs == [first, third])
    #expect(deselected.selectedIDs == [third])
  }

  @Test("Shift click extends through one lane")
  func shiftClickExtendsThroughOneLane() {
    let state = TaskBoardCardSelectionState(selectedIDs: [first], anchorID: first)

    let next = state.selecting(
      third,
      orderedVisibleIDs: [first, second, third],
      modifiers: .shift
    )

    #expect(next.selectedIDs == [first, second, third])
    #expect(next.anchorID == first)
  }

  @Test("Shift click with an anchor from another lane starts a new selection")
  func shiftClickAcrossLanesStartsNewSelection() {
    let state = TaskBoardCardSelectionState(selectedIDs: [first], anchorID: first)

    let next = state.selecting(
      third,
      orderedVisibleIDs: [third],
      modifiers: .shift
    )

    #expect(next.selectedIDs == [third])
    #expect(next.anchorID == third)
  }

  @Test("Pruning removes hidden cards and repairs the anchor")
  func pruningRemovesHiddenCardsAndRepairsAnchor() {
    let state = TaskBoardCardSelectionState(
      selectedIDs: [first, second, third],
      anchorID: third
    )

    let next = state.pruning(orderedVisibleIDs: [second, first])

    #expect(next.selectedIDs == [first, second])
    #expect(next.anchorID == second)
    #expect(next.orderedSelectedIDs(in: [second, first, third]) == [second, first])
  }

  @Test("Context menu priming replaces selection with its action scope")
  func contextMenuPrimingUsesActionScope() {
    let state = TaskBoardCardSelectionState(selectedIDs: [first, second], anchorID: first)

    let next = state.selectingForContextMenu([third])

    #expect(next.selectedIDs == [third])
    #expect(next.anchorID == third)
  }
}
