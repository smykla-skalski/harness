import Testing

@testable import HarnessMonitorKit

@Suite("Preview task-board lane transitions")
struct PreviewHarnessClientTaskBoardLaneTransitionTests {
  @Test("generic cross-lane updates compact source and shift destination anchors")
  func genericCrossLaneUpdateMaintainsAnchors() async throws {
    let client = PreviewHarnessClient(fixtures: .taskBoardBoardOnly, isLaunchAgentInstalled: true)
    let first = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(title: "first")
    )
    let second = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(title: "second")
    )
    let third = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(title: "third")
    )
    let unrelated = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(title: "unrelated")
    )

    try await setPosition(client, item: first, status: .todo, position: 0, actor: "first")
    try await setPosition(client, item: second, status: .todo, position: 1, actor: "second")
    try await setPosition(client, item: third, status: .planning, position: 0, actor: "third")
    try await setPosition(client, item: unrelated, status: .inProgress, position: 0, actor: "other")

    let firstBefore = try await client.taskBoardItemPositionSnapshot(id: first.id)
    let secondBefore = try await client.taskBoardItemPositionSnapshot(id: second.id)
    let thirdBefore = try await client.taskBoardItemPositionSnapshot(id: third.id)
    let unrelatedBefore = try await client.taskBoardItemPositionSnapshot(id: unrelated.id)
    let secondAnchor = try await client.taskBoardItem(id: second.id)
    let thirdAnchor = try await client.taskBoardItem(id: third.id)

    let moved = try await client.updateTaskBoardItem(
      id: first.id,
      request: TaskBoardUpdateItemRequest(status: .planning)
    )

    let secondAfter = try await client.taskBoardItem(id: second.id)
    let thirdAfter = try await client.taskBoardItem(id: third.id)
    let unrelatedAfter = try await client.taskBoardItem(id: unrelated.id)
    let movedSnapshot = try await client.taskBoardItemPositionSnapshot(id: first.id)
    let secondAfterSnapshot = try await client.taskBoardItemPositionSnapshot(id: second.id)
    let thirdAfterSnapshot = try await client.taskBoardItemPositionSnapshot(id: third.id)
    let unrelatedAfterSnapshot = try await client.taskBoardItemPositionSnapshot(id: unrelated.id)

    #expect(moved.status == .planning)
    #expect(moved.lanePosition == 0)
    #expect(moved.laneOrigin == .manual(actor: "first"))
    #expect(secondAfter.lanePosition == 0)
    #expect(secondAfter.laneOrigin == secondAnchor.laneOrigin)
    #expect(secondAfter.laneSetAt == secondAnchor.laneSetAt)
    #expect(thirdAfter.lanePosition == 1)
    #expect(thirdAfter.laneOrigin == thirdAnchor.laneOrigin)
    #expect(thirdAfter.laneSetAt == thirdAnchor.laneSetAt)
    #expect(unrelatedAfter.lanePosition == 0)
    #expect(movedSnapshot.itemRevision == firstBefore.itemRevision + 1)
    #expect(secondAfterSnapshot.itemRevision == secondBefore.itemRevision + 1)
    #expect(thirdAfterSnapshot.itemRevision == thirdBefore.itemRevision + 1)
    #expect(unrelatedAfterSnapshot.itemRevision == unrelatedBefore.itemRevision)
    #expect(movedSnapshot.itemsChangeSeq == firstBefore.itemsChangeSeq + 1)
  }

  @Test("generic deletion compacts only its source lane")
  func genericDeletionCompactsSourceLane() async throws {
    let client = PreviewHarnessClient(fixtures: .taskBoardBoardOnly, isLaunchAgentInstalled: true)
    let first = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(title: "first")
    )
    let second = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(title: "second")
    )
    let unrelated = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(title: "unrelated")
    )

    try await setPosition(client, item: first, status: .todo, position: 0, actor: "first")
    try await setPosition(client, item: second, status: .todo, position: 1, actor: "second")
    try await setPosition(client, item: unrelated, status: .planning, position: 0, actor: "other")

    let firstBefore = try await client.taskBoardItemPositionSnapshot(id: first.id)
    let secondBefore = try await client.taskBoardItemPositionSnapshot(id: second.id)
    let unrelatedBefore = try await client.taskBoardItemPositionSnapshot(id: unrelated.id)
    let secondAnchor = try await client.taskBoardItem(id: second.id)
    _ = try await client.deleteTaskBoardItem(id: first.id)

    let secondAfter = try await client.taskBoardItem(id: second.id)
    let unrelatedAfter = try await client.taskBoardItem(id: unrelated.id)
    let secondAfterSnapshot = try await client.taskBoardItemPositionSnapshot(id: second.id)
    let unrelatedAfterSnapshot = try await client.taskBoardItemPositionSnapshot(id: unrelated.id)

    #expect(secondAfter.lanePosition == 0)
    #expect(secondAfter.laneOrigin == secondAnchor.laneOrigin)
    #expect(secondAfter.laneSetAt == secondAnchor.laneSetAt)
    #expect(unrelatedAfter.lanePosition == 0)
    #expect(secondAfterSnapshot.itemRevision == secondBefore.itemRevision + 1)
    #expect(unrelatedAfterSnapshot.itemRevision == unrelatedBefore.itemRevision)
    #expect(secondAfterSnapshot.itemsChangeSeq == firstBefore.itemsChangeSeq + 1)
  }

  @Test("position snapshots omit filtered and tombstoned revisions")
  func positionSnapshotsFilterRevisionsAndRejectTombstones() async throws {
    let todo = taskBoardItem(id: "todo", status: .todo, lanePosition: 0)
    let planning = taskBoardItem(id: "planning", status: .planning, lanePosition: 0)
    let deleted = taskBoardItem(
      id: "deleted",
      status: .todo,
      lanePosition: 1,
      deletedAt: "2026-07-22T15:00:00Z"
    )
    let client = PreviewHarnessClient(
      fixtures: fixtures(taskBoardItems: [todo, planning, deleted]),
      isLaunchAgentInstalled: true
    )

    let snapshot = try await client.taskBoardItemsSnapshot(status: .todo)
    #expect(snapshot.items.map(\.id) == [todo.id])
    #expect(snapshot.itemRevisions == [todo.id: 1])

    do {
      _ = try await client.taskBoardItemPositionSnapshot(id: deleted.id)
      Issue.record("Expected tombstoned item snapshot to fail")
    } catch let error as HarnessMonitorAPIError {
      #expect(error == .server(code: 404, message: "Task board item unavailable"))
    }
  }

  @Test("planning dispatch and evaluation normalize anchored lanes once each")
  func lifecycleEntrypointsNormalizeAnchoredLanes() async throws {
    for lifecycle in Lifecycle.allCases {
      let client = PreviewHarnessClient(fixtures: .taskBoardBoardOnly, isLaunchAgentInstalled: true)
      let scenario = try await anchoredScenario(client, for: lifecycle)
      let movingBefore = try await client.taskBoardItemPositionSnapshot(id: scenario.moving.id)
      let trailingBefore = try await client.taskBoardItemPositionSnapshot(id: scenario.trailing.id)
      let destinationBefore = try await client.taskBoardItemPositionSnapshot(
        id: scenario.destination.id)
      let unrelatedBefore = try await client.taskBoardItemPositionSnapshot(
        id: scenario.unrelated.id)
      let trailingAnchor = try await client.taskBoardItem(id: scenario.trailing.id)
      let destinationAnchor = try await client.taskBoardItem(id: scenario.destination.id)

      try await lifecycle.apply(to: client, itemID: scenario.moving.id)

      let movingAfter = try await client.taskBoardItemPositionSnapshot(id: scenario.moving.id)
      let trailingAfter = try await client.taskBoardItem(id: scenario.trailing.id)
      let destinationAfter = try await client.taskBoardItem(id: scenario.destination.id)
      let trailingAfterSnapshot = try await client.taskBoardItemPositionSnapshot(
        id: scenario.trailing.id)
      let destinationAfterSnapshot = try await client.taskBoardItemPositionSnapshot(
        id: scenario.destination.id
      )
      let unrelatedAfter = try await client.taskBoardItemPositionSnapshot(id: scenario.unrelated.id)

      #expect(movingAfter.item.status == lifecycle.destinationStatus)
      #expect(movingAfter.item.lanePosition == 0)
      #expect(trailingAfter.lanePosition == 0)
      #expect(trailingAfter.laneOrigin == trailingAnchor.laneOrigin)
      #expect(trailingAfter.laneSetAt == trailingAnchor.laneSetAt)
      #expect(destinationAfter.lanePosition == 1)
      #expect(destinationAfter.laneOrigin == destinationAnchor.laneOrigin)
      #expect(destinationAfter.laneSetAt == destinationAnchor.laneSetAt)
      #expect(movingAfter.itemRevision == movingBefore.itemRevision + 1)
      #expect(trailingAfterSnapshot.itemRevision == trailingBefore.itemRevision + 1)
      #expect(destinationAfterSnapshot.itemRevision == destinationBefore.itemRevision + 1)
      #expect(unrelatedAfter.itemRevision == unrelatedBefore.itemRevision)
      #expect(movingAfter.itemsChangeSeq == movingBefore.itemsChangeSeq + 1)
    }
  }

  private func setPosition(
    _ client: PreviewHarnessClient,
    item: TaskBoardItem,
    status: TaskBoardStatus,
    position: UInt32,
    actor: String
  ) async throws {
    let snapshot = try await client.taskBoardItemPositionSnapshot(id: item.id)
    _ = try await client.setTaskBoardItemPosition(
      id: item.id,
      request: TaskBoardSetItemPositionRequest(
        status: status,
        lanePosition: position,
        expectedItemRevision: snapshot.itemRevision,
        expectedItemsChangeSeq: snapshot.itemsChangeSeq,
        actor: actor
      )
    )
  }

  private func anchoredScenario(
    _ client: PreviewHarnessClient,
    for lifecycle: Lifecycle
  ) async throws -> AnchoredScenario {
    let moving = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(title: "moving")
    )
    let trailing = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(title: "trailing")
    )
    let destination = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(title: "destination")
    )
    let unrelated = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(title: "unrelated")
    )
    try await setPosition(
      client, item: moving, status: lifecycle.sourceStatus, position: 0, actor: "moving"
    )
    try await setPosition(
      client, item: trailing, status: lifecycle.sourceStatus, position: 1, actor: "trailing"
    )
    try await setPosition(
      client, item: destination, status: lifecycle.destinationStatus, position: 0,
      actor: "destination"
    )
    try await setPosition(client, item: unrelated, status: .testing, position: 0, actor: "other")
    if lifecycle == .evaluation {
      _ = try await client.updateTaskBoardItem(
        id: moving.id,
        request: TaskBoardUpdateItemRequest(
          sessionId: "preview-session", workItemId: "preview-work")
      )
    }
    return AnchoredScenario(
      moving: moving,
      trailing: trailing,
      destination: destination,
      unrelated: unrelated
    )
  }

  private func fixtures(taskBoardItems: [TaskBoardItem]) -> PreviewHarnessClient.Fixtures {
    let base = PreviewHarnessClient.Fixtures.taskBoardBoardOnly
    return PreviewHarnessClient.Fixtures(
      health: base.health,
      projects: base.projects,
      sessions: base.sessions,
      detail: base.detail,
      timeline: base.timeline,
      readySessionID: base.readySessionID,
      detailsBySessionID: base.detailsBySessionID,
      coreDetailsBySessionID: base.coreDetailsBySessionID,
      timelinesBySessionID: base.timelinesBySessionID,
      agentTuisBySessionID: base.agentTuisBySessionID,
      codexRunsBySessionID: base.codexRunsBySessionID,
      taskBoardOrchestratorSettings: base.taskBoardOrchestratorSettings,
      taskBoardGitRuntimeConfig: base.taskBoardGitRuntimeConfig,
      taskBoardGitIdentityDefaults: base.taskBoardGitIdentityDefaults,
      taskBoardItems: taskBoardItems,
      reviewsResponse: base.reviewsResponse
    )
  }

  private func taskBoardItem(
    id: String,
    status: TaskBoardStatus,
    lanePosition: UInt32,
    deletedAt: String? = nil
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: id,
      body: "",
      status: status,
      priority: .medium,
      tags: [],
      projectId: nil,
      agentMode: .interactive,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      lanePosition: lanePosition,
      laneOrigin: .manual(actor: id),
      laneSetAt: "2026-07-22T14:00:00Z",
      createdAt: "2026-07-22T14:00:00Z",
      updatedAt: "2026-07-22T14:00:00Z",
      deletedAt: deletedAt
    )
  }

  private struct AnchoredScenario {
    let moving: TaskBoardItem
    let trailing: TaskBoardItem
    let destination: TaskBoardItem
    let unrelated: TaskBoardItem
  }

  private enum Lifecycle: CaseIterable, Equatable {
    case planning
    case dispatch
    case evaluation

    var sourceStatus: TaskBoardStatus {
      switch self {
      case .planning, .dispatch: .todo
      case .evaluation: .inProgress
      }
    }

    var destinationStatus: TaskBoardStatus {
      switch self {
      case .planning: .planning
      case .dispatch: .inProgress
      case .evaluation: .toReview
      }
    }

    func apply(to client: PreviewHarnessClient, itemID: String) async throws {
      switch self {
      case .planning:
        _ = try await client.beginTaskBoardPlan(id: itemID)
      case .dispatch:
        _ = try await client.dispatchTaskBoard(
          request: TaskBoardDispatchRequest(itemId: itemID, dryRun: false)
        )
      case .evaluation:
        _ = try await client.evaluateTaskBoard(
          request: TaskBoardEvaluateRequest(itemId: itemID, dryRun: false)
        )
      }
    }
  }
}
