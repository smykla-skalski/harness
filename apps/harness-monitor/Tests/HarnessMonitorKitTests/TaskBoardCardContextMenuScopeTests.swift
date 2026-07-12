import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Task board card context menu scope")
struct TaskBoardCardContextMenuScopeTests {
  private let first = TaskBoardCardID.api("board-a")
  private let second = TaskBoardCardID.api("board-b")
  private let third = TaskBoardCardID.inbox(sessionID: "session-a", taskID: "task-c")

  @Test("Right-clicking a selected card keeps the full selection")
  func selectedCardKeepsFullSelection() throws {
    let scope = try #require(
      TaskBoardCardContextMenuScope.resolve(
        menuSelection: [second],
        selectedIDs: [first, second],
        orderedVisibleIDs: [second, first, third]
      )
    )

    #expect(scope.cardIDs == [second, first])
    #expect(scope.copyIDsLabel == "Copy 2 Task IDs")
    #expect(scope.deleteLabel == "Delete 2 Tasks...")
  }

  @Test("Right-clicking an unselected card scopes actions to that card")
  func unselectedCardUsesSingleCardScope() throws {
    let scope = try #require(
      TaskBoardCardContextMenuScope.resolve(
        menuSelection: [third],
        selectedIDs: [first, second],
        orderedVisibleIDs: [first, second, third]
      )
    )

    #expect(scope.primaryID == third)
    #expect(scope.cardIDs == [third])
    #expect(scope.copyIDsLabel == "Copy Task ID")
    #expect(scope.deleteLabel == "Delete Task...")
    #expect(scope.clipboardText == "task-c")
  }

  @Test("Native multi-selection is preserved in visible order")
  func nativeMultiSelectionKeepsVisibleOrder() throws {
    let scope = try #require(
      TaskBoardCardContextMenuScope.resolve(
        menuSelection: [first, second],
        selectedIDs: [first, second],
        orderedVisibleIDs: [second, first, third]
      )
    )

    #expect(scope.cardIDs == [second, first])
    #expect(scope.clipboardText == "board-b\nboard-a")
  }

  @Test("An empty native selection has no actions")
  func emptySelectionHasNoActions() {
    #expect(
      TaskBoardCardContextMenuScope.resolve(
        menuSelection: [],
        selectedIDs: [first],
        orderedVisibleIDs: [first]
      ) == nil
    )
  }
}
