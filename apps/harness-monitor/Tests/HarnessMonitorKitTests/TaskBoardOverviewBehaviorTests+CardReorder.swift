import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

extension TaskBoardOverviewBehaviorTests {
  private func reorderFixture(status: TaskBoardStatus = .todo) -> [TaskBoardItem] {
    ["a", "b", "c", "d"].map { taskBoardItem(id: $0, status: status) }
  }

  private func reorderContext(
    itemID: String,
    sourceStatus: TaskBoardStatus = .todo,
    destinationLane: TaskBoardInboxLane = .todo,
    destinationItems: [TaskBoardItem]? = nil,
    insertionOffset: Int
  ) -> TaskBoardCardReorderDropContext {
    let status = destinationLane.taskBoardDropStatus ?? .todo
    return TaskBoardCardReorderDropContext(
      draggedItem: .api(itemID: itemID, status: sourceStatus),
      lane: destinationLane,
      apiItems: destinationItems ?? reorderFixture(status: status),
      insertionOffset: insertionOffset
    )
  }

  @Test("Native insertion offset moves a card before the first card")
  func reorderPlanMovesCardToFront() throws {
    let items = reorderFixture()
    let plan = try #require(
      TaskBoardCardReorderPlan.resolve(
        reorderContext(
          itemID: "d",
          destinationItems: items,
          insertionOffset: 0
        )
      )
    )

    #expect(plan.itemID == "d")
    #expect(plan.sourceStatus == .todo)
    #expect(plan.destinationStatus == .todo)
    #expect(plan.placement == .first)
    #expect(plan.placement.resolvePosition(itemID: "d", orderedItemIDs: items.map(\.id)) == 0)
  }

  @Test("Native insertion offset normalizes a later same-lane move")
  func reorderPlanMovesCardLater() throws {
    let items = reorderFixture()
    let plan = try #require(
      TaskBoardCardReorderPlan.resolve(
        reorderContext(
          itemID: "a",
          destinationItems: items,
          insertionOffset: 3
        )
      )
    )

    #expect(
      plan.placement
        == .relative(TaskBoardRelativeLanePlacement(anchorItemID: "d", edge: .before))
    )
    #expect(plan.placement.resolvePosition(itemID: "a", orderedItemIDs: items.map(\.id)) == 2)
  }

  @Test("Either native slot adjacent to the source is a same-lane no-op")
  func reorderPlanNoOpInAdjacentSourceSlots() {
    let items = reorderFixture()

    #expect(
      TaskBoardCardReorderPlan.dropDecision(
        isEnabled: true,
        reorderContext(
          itemID: "b",
          destinationItems: items,
          insertionOffset: 1
        )
      ) == .noChange
    )
    #expect(
      TaskBoardCardReorderPlan.dropDecision(
        isEnabled: true,
        reorderContext(
          itemID: "b",
          destinationItems: items,
          insertionOffset: 2
        )
      ) == .noChange
    )
  }

  @Test("Native insertion offset resolves an exact cross-lane anchor")
  func reorderPlanMovesAcrossLanesAtExactPosition() throws {
    let destinationItems = reorderFixture(status: .inProgress)
    let plan = try #require(
      TaskBoardCardReorderPlan.resolve(
        reorderContext(
          itemID: "source",
          destinationLane: .inProgress,
          destinationItems: destinationItems,
          insertionOffset: 2
        )
      )
    )

    #expect(plan.sourceStatus == .todo)
    #expect(plan.destinationStatus == .inProgress)
    #expect(
      plan.placement
        == .relative(TaskBoardRelativeLanePlacement(anchorItemID: "c", edge: .before))
    )
    #expect(
      plan.placement.resolvePosition(
        itemID: "source",
        orderedItemIDs: destinationItems.map(\.id)
      ) == 2
    )
  }

  @Test("Native insertion offsets cover empty and after-last destination slots")
  func reorderPlanMovesIntoEmptyAndLastSlots() throws {
    let emptyPlan = try #require(
      TaskBoardCardReorderPlan.resolve(
        reorderContext(
          itemID: "source",
          destinationLane: .inProgress,
          destinationItems: [],
          insertionOffset: 0
        )
      )
    )
    #expect(emptyPlan.placement == .first)
    #expect(emptyPlan.placement.resolvePosition(itemID: "source", orderedItemIDs: []) == 0)

    let items = reorderFixture(status: .inProgress)
    let lastPlan = try #require(
      TaskBoardCardReorderPlan.resolve(
        reorderContext(
          itemID: "source",
          destinationLane: .inProgress,
          destinationItems: items,
          insertionOffset: items.count
        )
      )
    )
    #expect(lastPlan.placement == .last)
    #expect(
      lastPlan.placement.resolvePosition(itemID: "source", orderedItemIDs: items.map(\.id))
        == UInt32(items.count)
    )
  }

  @Test("Context menu lane edges use canonical order hidden by board filters")
  func contextMenuLaneEdgesUseCanonicalOrder() async throws {
    var filters = TaskBoardFilterState()
    filters.toggleTag("visible")
    let hiddenTop = taskBoardItem(
      id: "hidden-top",
      status: .todo,
      tags: ["hidden"]
    )
    let selected = taskBoardItem(
      id: "selected",
      status: .todo,
      tags: ["visible"]
    )
    let otherLane = taskBoardItem(id: "planning", status: .planning)
    let filteredPresentation = await TaskBoardOverviewPresentationWorker().compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [hiddenTop, selected, otherLane],
        decisionItems: [],
        scopeSessionID: nil,
        taskBoardProjects: [],
        filters: filters
      )
    )
    #expect(filteredPresentation.apiItems(in: .todo).map(\.id) == [selected.id])

    let context = try #require(
      TaskBoardCardContextMenuEdgeMoveContext.resolve(
        cardID: .api(selected.id),
        canonicalItems: [hiddenTop, selected, otherLane]
      )
    )

    #expect(context.item.id == selected.id)
    #expect(context.lane == .todo)
    #expect(context.orderedItemIDs == [hiddenTop.id, selected.id])
    #expect(
      !TaskBoardCardContextMenuEdge.top.isCurrentEdge(
        itemID: selected.id,
        orderedItemIDs: context.orderedItemIDs
      )
    )
    #expect(
      TaskBoardCardContextMenuEdge.bottom.isCurrentEdge(
        itemID: selected.id,
        orderedItemIDs: context.orderedItemIDs
      )
    )
  }

  @Test("Position plan rejects stale, invalid, umbrella, and disabled delivery")
  func reorderPlanRejectsInvalidDelivery() {
    let items = reorderFixture(status: .inProgress)
    let invalidOffsetContext = reorderContext(
      itemID: "source",
      destinationLane: .inProgress,
      destinationItems: items,
      insertionOffset: items.count + 1
    )
    let staleSameLaneContext = reorderContext(
      itemID: "missing",
      destinationItems: reorderFixture(),
      insertionOffset: 1
    )
    let umbrellaContext = TaskBoardCardReorderDropContext(
      draggedItem: .api(itemID: "umbrella", status: .todo, kind: .umbrella),
      lane: .inProgress,
      apiItems: items,
      insertionOffset: 0
    )

    #expect(
      TaskBoardCardReorderPlan.dropDecision(isEnabled: true, invalidOffsetContext)
        == .reject("Cannot position task: the board changed before the drop completed")
    )
    #expect(
      TaskBoardCardReorderPlan.dropDecision(isEnabled: true, staleSameLaneContext)
        == .reject("Cannot position task: the board changed before the drop completed")
    )
    #expect(
      TaskBoardCardReorderPlan.dropDecision(isEnabled: true, umbrellaContext)
        == .reject("Cannot position task: it can no longer move to this lane")
    )
    #expect(
      TaskBoardCardReorderPlan.dropDecision(isEnabled: false, invalidOffsetContext)
        == .reject("Cannot position task: an action is already in progress")
    )
  }
}
