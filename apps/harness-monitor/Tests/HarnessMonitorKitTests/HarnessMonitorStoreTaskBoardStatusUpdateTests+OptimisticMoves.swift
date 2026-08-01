import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreTaskBoardStatusUpdateTests {
  @Test("Optimistic move shows the new status before the network call resolves")
  func optimisticMoveShowsNewStatusBeforeNetworkResolves() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      taskBoardItem(
        id: "board-1",
        status: .todo,
        sourceProjectId: "project-source",
        executionRepository: "acme/widget"
      )
    ])
    client.configureMutationDelay(.milliseconds(200))
    let store = await makeBootstrappedStore(client: client)

    let mutation = Task { @MainActor in
      await store.updateTaskBoardItemStatuses([
        TaskBoardItemStatusUpdate(id: "board-1", status: .inProgress)
      ])
    }

    var observedOptimisticItem: TaskBoardItem?
    _ = await waitUntil {
      guard let item = store.globalTaskBoardItems.first(where: { $0.id == "board-1" }),
        item.status == .inProgress
      else {
        return false
      }
      observedOptimisticItem = item
      return true
    }
    _ = await mutation.value

    #expect(observedOptimisticItem?.status == .inProgress)
    #expect(observedOptimisticItem?.sourceProjectId == "project-source")
    #expect(observedOptimisticItem?.executionRepository == "acme/widget")
    #expect(store.globalTaskBoardItems.first(where: { $0.id == "board-1" })?.status == .inProgress)
  }

  @Test("Optimistic move rolls back to the prior status on failure")
  func optimisticMoveRollsBackOnFailure() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([taskBoardItem(id: "board-1", status: .todo)])
    client.configureTaskBoardUpdateError(
      HarnessMonitorAPIError.server(code: 500, message: "boom")
    )
    let store = await makeBootstrappedStore(client: client)

    let success = await store.updateTaskBoardItemStatuses([
      TaskBoardItemStatusUpdate(id: "board-1", status: .inProgress)
    ])

    #expect(success == false)
    #expect(store.globalTaskBoardItems.first(where: { $0.id == "board-1" })?.status == .todo)
    #expect(store.currentFailureFeedbackMessage != nil)
  }

  @Test("Optimistic move preserves the item's kind")
  func optimisticMovePreservesKind() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      taskBoardItem(id: "board-1", status: .todo, kind: .umbrella)
    ])
    client.configureMutationDelay(.milliseconds(200))
    let store = await makeBootstrappedStore(client: client)

    let mutation = Task { @MainActor in
      await store.updateTaskBoardItemStatuses([
        TaskBoardItemStatusUpdate(id: "board-1", status: .inProgress)
      ])
    }

    var observedOptimisticKind: TaskBoardItemKind?
    _ = await waitUntil {
      guard let item = store.globalTaskBoardItems.first(where: { $0.id == "board-1" }),
        item.status == .inProgress
      else {
        return false
      }
      observedOptimisticKind = item.kind
      return true
    }
    _ = await mutation.value

    #expect(observedOptimisticKind == .umbrella)
    #expect(store.globalTaskBoardItems.first(where: { $0.id == "board-1" })?.kind == .umbrella)
  }

  @Test("Delayed optimistic move preserves placement metadata")
  func delayedOptimisticMovePreservesPlacementMetadata() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      taskBoardItem(
        id: "board-1",
        status: .todo,
        lanePosition: 2,
        laneOrigin: .automatic(producer: "daemon"),
        laneSetAt: "2026-07-22T14:00:00Z"
      )
    ])
    client.configureMutationDelay(.milliseconds(200))
    let store = await makeBootstrappedStore(client: client)

    let mutation = Task { @MainActor in
      await store.updateTaskBoardItemStatuses([
        TaskBoardItemStatusUpdate(id: "board-1", status: .inProgress)
      ])
    }

    var optimisticItem: TaskBoardItem?
    _ = await waitUntil {
      guard let item = store.globalTaskBoardItems.first(where: { $0.id == "board-1" }),
        item.status == .inProgress
      else {
        return false
      }
      optimisticItem = item
      return true
    }
    _ = await mutation.value

    #expect(optimisticItem?.lanePosition == 2)
    #expect(optimisticItem?.laneOrigin == .automatic(producer: "daemon"))
    #expect(optimisticItem?.laneSetAt == "2026-07-22T14:00:00Z")
  }
}
