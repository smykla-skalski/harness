import HarnessMonitorKit
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Task board card selection model")
struct TaskBoardCardSelectionModelTests {
  private let first = TaskBoardCardID.api("task-a")
  private let second = TaskBoardCardID.api("task-b")
  private let third = TaskBoardCardID.inbox(sessionID: "session-a", taskID: "task-c")

  @Test("Plain click replaces the selection")
  func plainClickReplacesSelection() {
    let model = TaskBoardCardSelectionModel()
    model.updateVisibleIDs([first, second, third])

    model.select(first, modifiers: [])
    model.select(second, modifiers: [])

    #expect(model.selectedIDs == [second])
  }

  @Test("Command click toggles membership without clearing the rest")
  func commandClickToggles() {
    let model = TaskBoardCardSelectionModel()
    model.updateVisibleIDs([first, second, third])

    model.select(first, modifiers: [])
    model.select(second, modifiers: .command)

    #expect(model.selectedIDs == [first, second])

    model.select(first, modifiers: .command)

    #expect(model.selectedIDs == [second])
  }

  @Test("Shift click extends the range from the anchor")
  func shiftClickExtendsRange() {
    let model = TaskBoardCardSelectionModel()
    model.updateVisibleIDs([first, second, third])

    model.select(first, modifiers: [])
    model.select(third, modifiers: .shift)

    #expect(model.selectedIDs == [first, second, third])
  }

  @Test("Starting a group drag preserves the existing multi-selection")
  func dragPreservesSelection() {
    let model = TaskBoardCardSelectionModel()
    model.updateVisibleIDs([first, second, third])
    model.select(first, modifiers: [])
    model.select(second, modifiers: .command)

    model.selectForDrag([first, second])

    #expect(model.selectedIDs == [first, second])
  }

  @Test("Dragging a card outside the selection replaces it")
  func dragOutsideSelectionReplaces() {
    let model = TaskBoardCardSelectionModel()
    model.updateVisibleIDs([first, second, third])
    model.select(first, modifiers: [])

    model.selectForDrag([third])

    #expect(model.selectedIDs == [third])
  }

  @Test("Visible-ID updates prune hidden cards from the selection")
  func visibleIDUpdatesPruneSelection() {
    let model = TaskBoardCardSelectionModel()
    model.updateVisibleIDs([first, second, third])
    model.select(first, modifiers: [])
    model.select(second, modifiers: .command)
    model.select(third, modifiers: .command)

    model.updateVisibleIDs([first, third])

    #expect(model.selectedIDs == [first, third])
    #expect(model.orderedSelectedIDs == [first, third])
  }

  @Test("Context menu priming replaces the selection with its scope")
  func contextMenuPrimingReplacesSelection() {
    let model = TaskBoardCardSelectionModel()
    model.updateVisibleIDs([first, second, third])
    model.select(first, modifiers: [])

    model.primeForContextMenu([second, third])

    #expect(model.selectedIDs == [second, third])
  }

  @Test("Opening a board-only item selects it locally without routing through actions")
  func openingBoardOnlyItemSelectsLocally() {
    let model = TaskBoardCardSelectionModel()
    let item = Self.makeItem(id: "board-only", sessionId: nil, workItemId: nil)

    model.openAPIItem(item, actions: TaskBoardOverviewActions(store: nil, scope: .dashboard))

    #expect(model.selectedItemID == "board-only")
    #expect(!model.isCreatingItem)
  }

  @Test("Opening a session-linked item does not select it locally")
  func openingLinkedItemDoesNotSelectLocally() {
    let model = TaskBoardCardSelectionModel()
    model.selectedItemID = "stale"
    let item = Self.makeItem(id: "linked", sessionId: "session-a", workItemId: "task-a")

    model.openAPIItem(item, actions: TaskBoardOverviewActions(store: nil, scope: .dashboard))

    #expect(model.selectedItemID == nil)
  }

  @Test("Begin-creating and clear-selection reset sheet routing state")
  func beginCreatingAndClearResetSheetState() {
    let model = TaskBoardCardSelectionModel()
    model.selectedItemID = "task-a"

    model.beginCreatingItem()
    #expect(model.isCreatingItem)
    #expect(model.selectedItemID == nil)

    model.selectedItemID = "task-b"
    model.clearSelectedItem()
    #expect(model.selectedItemID == nil)
    #expect(!model.isCreatingItem)
  }

  private static func makeItem(
    id: String,
    sessionId: String?,
    workItemId: String?
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Selection model fixture",
      body: "",
      status: .todo,
      priority: .medium,
      tags: [],
      projectId: nil,
      agentMode: .interactive,
      externalRefs: [],
      planning: TaskBoardPlanningState(summary: nil),
      workflow: nil,
      sessionId: sessionId,
      workItemId: workItemId,
      usage: TaskBoardUsage(),
      createdAt: "2026-05-19T10:10:00Z",
      updatedAt: "2026-05-19T10:11:00Z",
      deletedAt: nil
    )
  }
}
