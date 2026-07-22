import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

extension TaskBoardOverviewBehaviorTests {
  private func reorderFixture() -> [TaskBoardItem] {
    [
      taskBoardItem(id: "a", status: .todo),
      taskBoardItem(id: "b", status: .todo),
      taskBoardItem(id: "c", status: .todo),
      taskBoardItem(id: "d", status: .todo),
    ]
  }

  @Test("Reorder plan moves a card to the front when dropped above the first card")
  func reorderPlanMovesCardToFront() throws {
    let items = reorderFixture()

    let plan = try #require(
      TaskBoardCardReorderPlan.resolve(
        draggedItemID: "d",
        lane: .todo,
        apiItems: items,
        hoveredItemID: "a",
        insertAfterHovered: false
      )
    )

    #expect(plan.itemID == "d")
    #expect(plan.status == .todo)
    #expect(plan.placement.anchorItemID == "a")
    #expect(plan.placement.edge == .before)
    #expect(plan.placement.resolvePosition(itemID: "d", orderedItemIDs: items.map(\.id)) == 0)
  }

  @Test("Reorder plan moves a card later when dropped below a card past it")
  func reorderPlanMovesCardLater() throws {
    let items = reorderFixture()

    let plan = try #require(
      TaskBoardCardReorderPlan.resolve(
        draggedItemID: "a",
        lane: .todo,
        apiItems: items,
        hoveredItemID: "c",
        insertAfterHovered: true
      )
    )

    #expect(plan.placement.resolvePosition(itemID: "a", orderedItemIDs: items.map(\.id)) == 2)
  }

  @Test("Reorder plan is a no-op when dropped above the card immediately after it")
  func reorderPlanNoOpImmediatelyAfter() {
    let items = reorderFixture()

    #expect(
      TaskBoardCardReorderPlan.resolve(
        draggedItemID: "a",
        lane: .todo,
        apiItems: items,
        hoveredItemID: "b",
        insertAfterHovered: false
      ) == nil
    )
  }

  @Test("Reorder plan is a no-op when a card is dropped on itself, either half")
  func reorderPlanNoOpOnSelf() {
    let items = reorderFixture()

    #expect(
      TaskBoardCardReorderPlan.resolve(
        draggedItemID: "b",
        lane: .todo,
        apiItems: items,
        hoveredItemID: "b",
        insertAfterHovered: false
      ) == nil
    )
    #expect(
      TaskBoardCardReorderPlan.resolve(
        draggedItemID: "b",
        lane: .todo,
        apiItems: items,
        hoveredItemID: "b",
        insertAfterHovered: true
      ) == nil
    )
  }

  @Test("Reorder plan rejects a dragged item whose lane does not match")
  func reorderPlanRejectsMismatchedLane() {
    let items = [
      taskBoardItem(id: "a", status: .inProgress),
      taskBoardItem(id: "b", status: .todo),
    ]

    #expect(
      TaskBoardCardReorderPlan.resolve(
        draggedItemID: "a",
        lane: .todo,
        apiItems: items,
        hoveredItemID: "b",
        insertAfterHovered: false
      ) == nil
    )
  }

  @Test("Reorder plan rejects unknown dragged or hovered identifiers")
  func reorderPlanRejectsUnknownIdentifiers() {
    let items = reorderFixture()

    #expect(
      TaskBoardCardReorderPlan.resolve(
        draggedItemID: "missing",
        lane: .todo,
        apiItems: items,
        hoveredItemID: "a",
        insertAfterHovered: false
      ) == nil
    )
    #expect(
      TaskBoardCardReorderPlan.resolve(
        draggedItemID: "a",
        lane: .todo,
        apiItems: items,
        hoveredItemID: "missing",
        insertAfterHovered: false
      ) == nil
    )
  }

  @Test("Reorder plan drops the first card to the end when dropped below the last card")
  func reorderPlanMovesFirstCardToEnd() throws {
    let items = reorderFixture()

    let plan = try #require(
      TaskBoardCardReorderPlan.resolve(
        draggedItemID: "a",
        lane: .todo,
        apiItems: items,
        hoveredItemID: "d",
        insertAfterHovered: true
      )
    )

    #expect(plan.placement.resolvePosition(itemID: "a", orderedItemIDs: items.map(\.id)) == 3)
  }

  @Test("Reorder plan rejects the visual umbrella lane because it spans persisted statuses")
  func reorderPlanRejectsUmbrellaLane() {
    let items = [
      taskBoardItem(id: "open", status: .todo, kind: .umbrella),
      taskBoardItem(id: "closed", status: .done, kind: .umbrella),
    ]

    #expect(
      TaskBoardCardReorderPlan.resolve(
        draggedItemID: "closed",
        lane: .umbrella,
        apiItems: items,
        hoveredItemID: "open",
        insertAfterHovered: false
      ) == nil
    )
  }
}
