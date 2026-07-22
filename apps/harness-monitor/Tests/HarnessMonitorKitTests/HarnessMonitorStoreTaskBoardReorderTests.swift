import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board reorder")
struct HarnessMonitorStoreTaskBoardReorderTests {
  @Test("Reordering a card resolves and stores its relative lane position")
  func reorderResolvesRelativeLanePosition() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      taskBoardItem(id: "board-1", status: .todo),
      taskBoardItem(id: "board-2", status: .todo),
    ])
    let store = await makeBootstrappedStore(client: client)

    let success = await store.reorderTaskBoardItem(
      id: "board-1",
      status: .todo,
      placement: placement(after: "board-2")
    )

    #expect(success)
    #expect(
      client.recordedCalls() == [
        .setTaskBoardItemPosition(id: "board-1", status: .todo, lanePosition: 1)
      ]
    )
    let item = store.globalTaskBoardItems.first(where: { $0.id == "board-1" })
    #expect(item?.lanePosition == 1)
    #expect(item?.laneOrigin == .manual(actor: "Harness Monitor"))
    #expect(store.currentSuccessFeedbackMessage == "Reordered task board item")
  }

  @Test("A concurrent same-lane reorder recomputes the slot from the stable anchor")
  func reorderRecomputesSlotAfterConflict() async {
    let client = RecordingHarnessClient()
    let itemA = taskBoardItem(id: "a", status: .todo)
    let itemB = taskBoardItem(id: "b", status: .todo)
    let itemC = taskBoardItem(id: "c", status: .todo)
    client.configureTaskBoardItems([itemA, itemB, itemC])
    client.taskBoardPositionError = concurrentModificationError
    client.taskBoardPositionErrorRemainingUses = 1
    client.taskBoardPositionItemsAfterError = [itemC, itemA, itemB]
    let store = await makeBootstrappedStore(client: client)

    let success = await store.reorderTaskBoardItem(
      id: "a",
      status: .todo,
      placement: placement(after: "b")
    )

    #expect(success)
    let setCalls = client.recordedCalls().compactMap { call -> UInt32? in
      guard case .setTaskBoardItemPosition(_, _, let position) = call else { return nil }
      return position
    }
    #expect(setCalls == [1, 2])
  }

  @Test("A concurrent lane move fails closed instead of moving the card back")
  func reorderRejectsConcurrentLaneMove() async {
    let client = RecordingHarnessClient()
    let itemA = taskBoardItem(id: "a", status: .todo)
    let itemB = taskBoardItem(id: "b", status: .todo)
    client.configureTaskBoardItems([itemA, itemB])
    client.taskBoardPositionError = concurrentModificationError
    client.taskBoardPositionErrorRemainingUses = 1
    client.taskBoardPositionItemsAfterError = [
      taskBoardItem(id: "a", status: .inProgress),
      itemB,
    ]
    let store = await makeBootstrappedStore(client: client)

    let success = await store.reorderTaskBoardItem(
      id: "a",
      status: .todo,
      placement: placement(after: "b")
    )

    #expect(success == false)
    let setCalls = client.recordedCalls().filter {
      if case .setTaskBoardItemPosition = $0 { return true }
      return false
    }
    #expect(setCalls.count == 1)
    #expect(store.currentFailureFeedbackMessage != nil)
  }

  @Test("A non-concurrency 409 is not retried")
  func reorderDoesNotRetryCapacityConflict() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      taskBoardItem(id: "a", status: .todo),
      taskBoardItem(id: "b", status: .todo),
    ])
    client.taskBoardPositionError = HarnessMonitorAPIError.semanticServer(
      code: 409,
      semanticCode: "TASK_BOARD_LANE_CAPACITY",
      message: "Task board lane capacity changed"
    )
    client.taskBoardPositionErrorRemainingUses = 1
    let store = await makeBootstrappedStore(client: client)

    let success = await store.reorderTaskBoardItem(
      id: "a",
      status: .todo,
      placement: placement(after: "b")
    )

    #expect(success == false)
    let setCalls = client.recordedCalls().filter {
      if case .setTaskBoardItemPosition = $0 { return true }
      return false
    }
    #expect(setCalls.count == 1)
  }

  @Test("Relative placement includes umbrellas hidden from the visual status lane")
  func reorderUsesCanonicalStatusLaneSlots() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      taskBoardItem(id: "umbrella", status: .todo, kind: .umbrella),
      taskBoardItem(id: "a", status: .todo),
      taskBoardItem(id: "b", status: .todo),
    ])
    let store = await makeBootstrappedStore(client: client)

    let success = await store.reorderTaskBoardItem(
      id: "a",
      status: .todo,
      placement: placement(after: "b")
    )

    #expect(success)
    #expect(
      client.recordedCalls().contains(
        .setTaskBoardItemPosition(id: "a", status: .todo, lanePosition: 2)
      )
    )
  }

  @Test("Resetting a manually placed item clears its lane placement")
  func resetClearsManualPlacement() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      taskBoardItem(
        id: "board-1",
        status: .todo,
        lanePosition: 0,
        laneOrigin: .manual(actor: "Harness Monitor")
      )
    ])
    let store = await makeBootstrappedStore(client: client)

    let success = await store.resetTaskBoardItemManualPosition(id: "board-1")

    #expect(success)
    #expect(client.recordedCalls() == [.resetTaskBoardItemPosition(id: "board-1")])
    let item = store.globalTaskBoardItems.first(where: { $0.id == "board-1" })
    #expect(item?.lanePosition == nil)
    #expect(item?.laneOrigin == nil)
    #expect(store.currentSuccessFeedbackMessage == "Reset task board position")
  }

  @Test("Reset retries a global conflict only while the item revision is unchanged")
  func resetRetriesUnrelatedConflict() async {
    let client = RecordingHarnessClient()
    let item = taskBoardItem(
      id: "board-1",
      status: .todo,
      lanePosition: 0,
      laneOrigin: .manual(actor: "Harness Monitor")
    )
    client.configureTaskBoardItems([item])
    client.taskBoardPositionError = concurrentModificationError
    client.taskBoardPositionErrorRemainingUses = 1
    client.taskBoardPositionItemsAfterError = [item]
    let store = await makeBootstrappedStore(client: client)

    let success = await store.resetTaskBoardItemManualPosition(id: "board-1")

    #expect(success)
    #expect(
      client.recordedCalls() == [
        .resetTaskBoardItemPosition(id: "board-1"),
        .resetTaskBoardItemPosition(id: "board-1"),
      ]
    )
  }

  @Test("Reset fails closed when the positioned item changed during a conflict")
  func resetRejectsChangedItem() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      taskBoardItem(
        id: "board-1",
        status: .todo,
        lanePosition: 1,
        laneOrigin: .manual(actor: "Harness Monitor")
      ),
      taskBoardItem(id: "board-2", status: .todo),
    ])
    client.taskBoardPositionError = concurrentModificationError
    client.taskBoardPositionErrorRemainingUses = 1
    client.taskBoardPositionItemsAfterError = [
      taskBoardItem(
        id: "board-1",
        status: .todo,
        lanePosition: 0,
        laneOrigin: .manual(actor: "Other client")
      ),
      taskBoardItem(id: "board-2", status: .todo),
    ]
    let store = await makeBootstrappedStore(client: client)

    let success = await store.resetTaskBoardItemManualPosition(id: "board-1")

    #expect(success == false)
    let resetCalls = client.recordedCalls().filter {
      if case .resetTaskBoardItemPosition = $0 { return true }
      return false
    }
    #expect(resetCalls.count == 1)
  }

  private var concurrentModificationError: HarnessMonitorAPIError {
    .semanticServer(
      code: 409,
      semanticCode: "WORKFLOW_CONCURRENT",
      message: "Task board position changed"
    )
  }

  private func placement(after itemID: String) -> TaskBoardRelativeLanePlacement {
    TaskBoardRelativeLanePlacement(anchorItemID: itemID, edge: .after)
  }

  private func taskBoardItem(
    id: String,
    status: TaskBoardStatus,
    kind: TaskBoardItemKind = .task,
    lanePosition: UInt32? = nil,
    laneOrigin: TaskBoardLaneOrigin? = nil
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Board item \(id)",
      body: "Body",
      status: status,
      priority: .medium,
      tags: [],
      projectId: "project-1",
      agentMode: .interactive,
      kind: kind,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      lanePosition: lanePosition,
      laneOrigin: laneOrigin,
      laneSetAt: nil,
      createdAt: "2026-05-14T10:00:00Z",
      updatedAt: "2026-05-14T10:01:00Z",
      deletedAt: nil
    )
  }
}
