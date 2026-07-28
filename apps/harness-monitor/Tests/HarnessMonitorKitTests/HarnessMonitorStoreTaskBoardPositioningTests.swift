import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board positioning")
struct HarnessMonitorStoreTaskBoardPositioningTests {
  @Test("A card moves across lanes at an exact position in one mutation")
  func crossLaneMoveUsesDestinationAnchorAndCountsUmbrellas() async throws {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      taskBoardItem(
        id: "moving",
        status: .todo,
        sourceProjectId: "project-source",
        executionRepository: "acme/widget"
      ),
      taskBoardItem(id: "umbrella", status: .planning, kind: .umbrella),
      taskBoardItem(id: "anchor", status: .planning),
      taskBoardItem(id: "trailing", status: .planning),
    ])
    let store = await makeBootstrappedStore(client: client)

    let success = await store.positionTaskBoardItem(
      id: "moving",
      sourceStatus: .todo,
      destinationStatus: .planning,
      placement: .relative(relative(after: "anchor"))
    )
    let destination = try await client.taskBoardItemsSnapshot(status: .planning)

    #expect(success)
    #expect(store.currentSuccessFeedbackMessage == nil)
    #expect(destination.items.map(\.id) == ["umbrella", "anchor", "moving", "trailing"])
    #expect(destination.items.first(where: { $0.id == "moving" })?.sourceProjectId == "project-source")
    #expect(
      destination.items.first(where: { $0.id == "moving" })?.executionRepository == "acme/widget"
    )
    #expect(
      client.recordedCallsIgnoringProjectCatalogReads() == [
        .setTaskBoardItemPosition(id: "moving", status: .planning, lanePosition: 2)
      ]
    )
  }

  @Test("A dropped card settles before its daemon mutation starts")
  func dropAppliesOptimisticPositionSynchronously() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      taskBoardItem(
        id: "moving",
        status: .todo,
        sourceProjectId: "project-source",
        executionRepository: "acme/widget"
      ),
      taskBoardItem(id: "anchor", status: .planning),
      taskBoardItem(id: "trailing", status: .planning),
    ])
    let store = await makeBootstrappedStore(client: client)
    let placement = TaskBoardLanePlacement.relative(relative(after: "anchor"))

    let optimisticMutation = store.beginOptimisticTaskBoardPosition(
      id: "moving",
      sourceStatus: .todo,
      destinationStatus: .planning,
      placement: placement
    )

    #expect(optimisticMutation != nil)
    #expect(store.isTaskBoardBusy)
    #expect(await waitUntil { store.contentUI.dashboard.isTaskBoardBusy })
    #expect(store.globalTaskBoardItems.map(\.id) == ["anchor", "moving", "trailing"])
    #expect(store.contentUI.dashboard.taskBoardItems.map(\.id) == ["anchor", "moving", "trailing"])
    let optimisticItem = store.globalTaskBoardItems.first(where: { $0.id == "moving" })
    #expect(optimisticItem?.status == .planning)
    #expect(optimisticItem?.lanePosition == 1)
    #expect(optimisticItem?.laneOrigin == .manual(actor: "Harness Monitor"))
    #expect(optimisticItem?.sourceProjectId == "project-source")
    #expect(optimisticItem?.executionRepository == "acme/widget")
    #expect(client.recordedCallsIgnoringProjectCatalogReads().isEmpty)

    let success = await store.positionTaskBoardItem(
      id: "moving",
      sourceStatus: .todo,
      destinationStatus: .planning,
      placement: placement,
      optimisticMutation: optimisticMutation
    )

    #expect(success)
    #expect(!store.isTaskBoardBusy)
    #expect(store.globalTaskBoardItems.map(\.id) == ["anchor", "moving", "trailing"])
    #expect(
      store.globalTaskBoardItems.first(where: { $0.id == "moving" })?.sourceProjectId
        == "project-source"
    )
    #expect(
      store.globalTaskBoardItems.first(where: { $0.id == "moving" })?.executionRepository
        == "acme/widget"
    )
  }

  @Test("A disconnected optimistic move releases task-board busy state")
  func disconnectedOptimisticMoveReleasesBusyState() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      taskBoardItem(id: "moving", status: .todo),
      taskBoardItem(id: "anchor", status: .planning),
    ])
    let store = await makeBootstrappedStore(client: client)
    let placement = TaskBoardLanePlacement.relative(relative(after: "anchor"))
    let optimisticMutation = store.beginOptimisticTaskBoardPosition(
      id: "moving",
      sourceStatus: .todo,
      destinationStatus: .planning,
      placement: placement
    )

    #expect(optimisticMutation != nil)
    #expect(await waitUntil { store.contentUI.dashboard.isTaskBoardBusy })
    store.client = nil

    let success = await store.positionTaskBoardItem(
      id: "moving",
      sourceStatus: .todo,
      destinationStatus: .planning,
      placement: placement,
      optimisticMutation: optimisticMutation
    )

    #expect(success == false)
    #expect(!store.isTaskBoardBusy)
    #expect(await waitUntil { !store.contentUI.dashboard.isTaskBoardBusy })
    #expect(store.globalTaskBoardItems.map(\.id) == ["moving", "anchor"])
    #expect(store.globalTaskBoardItems.first?.status == .todo)
  }

  @Test("Optimism rejects a stale source lane without starting persistence")
  func staleSourceStatusRejectsBeforePersistence() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      taskBoardItem(id: "moving", status: .inProgress),
      taskBoardItem(id: "anchor", status: .planning),
    ])
    let store = await makeBootstrappedStore(client: client)
    client.clearRecordedCalls()
    let originalItems = store.globalTaskBoardItems

    let optimisticMutation = store.beginOptimisticTaskBoardPosition(
      id: "moving",
      sourceStatus: .todo,
      destinationStatus: .planning,
      placement: .relative(relative(after: "anchor"))
    )
    let success = await store.positionTaskBoardItem(
      id: "moving",
      sourceStatus: .todo,
      destinationStatus: .planning,
      placement: .relative(relative(after: "anchor")),
      optimisticMutation: optimisticMutation
    )

    #expect(optimisticMutation == nil)
    #expect(success == false)
    #expect(store.globalTaskBoardItems == originalItems)
    #expect(store.currentFailureFeedbackMessage == nil)
    #expect(client.recordedCallsIgnoringProjectCatalogReads().isEmpty)
  }

  @Test("A failed optimistic move preserves an unrelated item update")
  func rollbackPreservesUnrelatedItemUpdate() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      taskBoardItem(id: "moving", status: .todo),
      taskBoardItem(id: "other", status: .todo),
      taskBoardItem(id: "anchor", status: .planning),
    ])
    let store = await makeBootstrappedStore(client: client)
    let placement = TaskBoardLanePlacement.relative(relative(after: "anchor"))
    let optimisticMutation = store.beginOptimisticTaskBoardPosition(
      id: "moving",
      sourceStatus: .todo,
      destinationStatus: .planning,
      placement: placement
    )
    #expect(optimisticMutation != nil)
    let updatedOther = taskBoardItem(
      id: "other",
      status: .todo,
      title: "Updated by another operation"
    )
    store.globalTaskBoardItems = store.globalTaskBoardItems.map {
      $0.id == updatedOther.id ? updatedOther : $0
    }
    client.taskBoardPositionError = HarnessMonitorAPIError.server(
      code: 500,
      message: "Position failed"
    )
    client.taskBoardPositionErrorRemainingUses = 1
    client.configureTaskBoardItemsErrors([
      HarnessMonitorAPIError.server(code: 503, message: "Refresh unavailable")
    ])

    let success = await store.positionTaskBoardItem(
      id: "moving",
      sourceStatus: .todo,
      destinationStatus: .planning,
      placement: placement,
      optimisticMutation: optimisticMutation
    )

    #expect(success == false)
    #expect(
      store.globalTaskBoardItems.first(where: { $0.id == "moving" })?.status == .todo
    )
    #expect(
      store.globalTaskBoardItems.first(where: { $0.id == "other" })?.title
        == "Updated by another operation"
    )
  }

  @Test("A cross-lane card can be placed before a destination anchor")
  func crossLaneMoveSupportsBeforePlacement() async throws {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      taskBoardItem(id: "moving", status: .todo),
      taskBoardItem(id: "anchor", status: .planning),
      taskBoardItem(id: "trailing", status: .planning),
    ])
    let store = await makeBootstrappedStore(client: client)

    let success = await store.positionTaskBoardItem(
      id: "moving",
      sourceStatus: .todo,
      destinationStatus: .planning,
      placement: .relative(relative(before: "anchor"))
    )
    let destination = try await client.taskBoardItemsSnapshot(status: .planning)

    #expect(success)
    #expect(destination.items.map(\.id) == ["moving", "anchor", "trailing"])
    #expect(
      client.recordedCallsIgnoringProjectCatalogReads() == [
        .setTaskBoardItemPosition(id: "moving", status: .planning, lanePosition: 0)
      ]
    )
  }

  @Test("A card can move into an empty lane")
  func crossLaneMoveSupportsEmptyDestination() async throws {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      taskBoardItem(id: "moving", status: .todo)
    ])
    let store = await makeBootstrappedStore(client: client)

    let success = await store.positionTaskBoardItem(
      id: "moving",
      sourceStatus: .todo,
      destinationStatus: .testing,
      placement: .last
    )
    let destination = try await client.taskBoardItemsSnapshot(status: .testing)

    #expect(success)
    #expect(destination.items.map(\.id) == ["moving"])
    #expect(
      client.recordedCallsIgnoringProjectCatalogReads() == [
        .setTaskBoardItemPosition(id: "moving", status: .testing, lanePosition: 0)
      ]
    )
  }

  @Test("A card can move to the first and last exact lane slots")
  func sameLaneMoveSupportsFirstAndLast() async throws {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      taskBoardItem(id: "umbrella", status: .todo, kind: .umbrella),
      taskBoardItem(id: "a", status: .todo),
      taskBoardItem(id: "b", status: .todo),
      taskBoardItem(id: "c", status: .todo),
    ])
    let store = await makeBootstrappedStore(client: client)

    let movedFirst = await store.positionTaskBoardItem(
      id: "c",
      sourceStatus: .todo,
      destinationStatus: .todo,
      placement: .first
    )
    let movedLast = await store.positionTaskBoardItem(
      id: "c",
      sourceStatus: .todo,
      destinationStatus: .todo,
      placement: .last
    )
    let lane = try await client.taskBoardItemsSnapshot(status: .todo)

    #expect(movedFirst)
    #expect(movedLast)
    #expect(lane.items.map(\.id) == ["umbrella", "a", "b", "c"])
    #expect(
      client.recordedCallsIgnoringProjectCatalogReads() == [
        .setTaskBoardItemPosition(id: "c", status: .todo, lanePosition: 0),
        .setTaskBoardItemPosition(id: "c", status: .todo, lanePosition: 3),
      ]
    )
  }

  @Test("A cross-lane conflict recomputes the slot from the stable anchor")
  func crossLaneMoveRecomputesSlotAfterConflict() async {
    let client = RecordingHarnessClient()
    let moving = taskBoardItem(id: "moving", status: .todo)
    let anchor = taskBoardItem(id: "anchor", status: .planning)
    let trailing = taskBoardItem(id: "trailing", status: .planning)
    client.configureTaskBoardItems([moving, anchor, trailing])
    client.taskBoardPositionError = concurrentModificationError
    client.taskBoardPositionErrorRemainingUses = 1
    client.taskBoardPositionItemsAfterError = [trailing, moving, anchor]
    let store = await makeBootstrappedStore(client: client)

    let success = await store.positionTaskBoardItem(
      id: "moving",
      sourceStatus: .todo,
      destinationStatus: .planning,
      placement: .relative(relative(after: "anchor"))
    )

    #expect(success)
    let setCalls = client.recordedCalls().compactMap { call -> UInt32? in
      guard case .setTaskBoardItemPosition(_, _, let position) = call else { return nil }
      return position
    }
    #expect(setCalls == [1, 2])
  }

  @Test("A cross-lane retry fails closed when the source card moved")
  func crossLaneMoveRejectsConcurrentSourceLaneChange() async {
    let client = RecordingHarnessClient()
    let moving = taskBoardItem(id: "moving", status: .todo)
    let anchor = taskBoardItem(id: "anchor", status: .planning)
    client.configureTaskBoardItems([moving, anchor])
    client.taskBoardPositionError = concurrentModificationError
    client.taskBoardPositionErrorRemainingUses = 1
    client.taskBoardPositionItemsAfterError = [
      taskBoardItem(id: "moving", status: .inProgress),
      anchor,
    ]
    let store = await makeBootstrappedStore(client: client)

    let success = await store.positionTaskBoardItem(
      id: "moving",
      sourceStatus: .todo,
      destinationStatus: .planning,
      placement: .relative(relative(after: "anchor"))
    )

    #expect(success == false)
    let setCalls = client.recordedCalls().filter {
      if case .setTaskBoardItemPosition = $0 { return true }
      return false
    }
    #expect(setCalls.count == 1)
    #expect(
      store.globalTaskBoardItems.first(where: { $0.id == "moving" })?.status == .inProgress
    )
    #expect(
      store.currentFailureFeedbackMessage
        == "Cannot update task board position: the board changed before the action completed"
    )
  }

  private var concurrentModificationError: HarnessMonitorAPIError {
    .semanticServer(
      code: 409,
      semanticCode: "WORKFLOW_CONCURRENT",
      message: "Task board position changed"
    )
  }

  private func relative(after itemID: String) -> TaskBoardRelativeLanePlacement {
    TaskBoardRelativeLanePlacement(anchorItemID: itemID, edge: .after)
  }

  private func relative(before itemID: String) -> TaskBoardRelativeLanePlacement {
    TaskBoardRelativeLanePlacement(anchorItemID: itemID, edge: .before)
  }

  private func taskBoardItem(
    id: String,
    status: TaskBoardStatus,
    kind: TaskBoardItemKind = .task,
    sourceProjectId: String? = nil,
    executionRepository: String? = nil,
    title: String? = nil
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: title ?? "Board item \(id)",
      body: "Body",
      status: status,
      priority: .medium,
      tags: [],
      projectId: "project-1",
      sourceProjectId: sourceProjectId,
      executionRepository: executionRepository,
      agentMode: .interactive,
      kind: kind,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      lanePosition: nil,
      laneOrigin: nil,
      laneSetAt: nil,
      createdAt: "2026-05-14T10:00:00Z",
      updatedAt: "2026-05-14T10:01:00Z",
      deletedAt: nil
    )
  }
}
