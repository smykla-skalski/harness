import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board reorder")
struct HarnessMonitorStoreTaskBoardReorderTests {
  @Test("Reordering a card sends the computed lane position and stores the manual result")
  func reorderSendsComputedLanePosition() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([taskBoardItem(id: "board-1", status: .todo)])
    let store = await makeBootstrappedStore(client: client)

    let success = await store.reorderTaskBoardItem(id: "board-1", status: .todo, lanePosition: 1)

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

  @Test("A stale CAS conflict retries once against a fresh snapshot before succeeding")
  func reorderRetriesOnceOnConflict() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([taskBoardItem(id: "board-1", status: .todo)])
    client.taskBoardPositionError = HarnessMonitorAPIError.server(
      code: 409,
      message: "Task board position is stale"
    )
    client.taskBoardPositionErrorRemainingUses = 1
    let store = await makeBootstrappedStore(client: client)

    let success = await store.reorderTaskBoardItem(id: "board-1", status: .todo, lanePosition: 0)

    #expect(success)
    let setCalls = client.recordedCalls().filter {
      if case .setTaskBoardItemPosition = $0 { return true }
      return false
    }
    #expect(setCalls.count == 2)
    #expect(store.globalTaskBoardItems.first(where: { $0.id == "board-1" })?.lanePosition == 0)
  }

  @Test("A conflict that persists past the retry budget surfaces as a failure")
  func reorderFailsAfterExhaustingRetry() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([taskBoardItem(id: "board-1", status: .todo)])
    client.taskBoardPositionError = HarnessMonitorAPIError.server(
      code: 409,
      message: "Task board position is stale"
    )
    client.taskBoardPositionErrorRemainingUses = 2
    let store = await makeBootstrappedStore(client: client)

    let success = await store.reorderTaskBoardItem(id: "board-1", status: .todo, lanePosition: 0)

    #expect(success == false)
    #expect(store.currentFailureFeedbackMessage != nil)
  }

  @Test("Resetting a manually placed item clears its lane placement")
  func resetClearsManualPlacement() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      taskBoardItem(
        id: "board-1",
        status: .todo,
        lanePosition: 2,
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

  private func taskBoardItem(
    id: String,
    status: TaskBoardStatus,
    lanePosition: UInt32? = nil,
    laneOrigin: TaskBoardLaneOrigin? = nil
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Board item",
      body: "Body",
      status: status,
      priority: .medium,
      tags: [],
      projectId: "project-1",
      agentMode: .interactive,
      kind: .task,
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
