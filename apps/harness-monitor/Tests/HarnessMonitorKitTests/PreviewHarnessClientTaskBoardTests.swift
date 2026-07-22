import Testing

@testable import HarnessMonitorKit

@Suite("Preview harness client task board")
struct PreviewHarnessClientTaskBoardTests {
  @Test("Preview client mutates task board items and orchestrator status")
  func previewClientMutatesTaskBoardItemsAndOrchestratorStatus() async throws {
    let client = PreviewHarnessClient(
      fixtures: .taskBoardBoardOnly,
      isLaunchAgentInstalled: true
    )

    let created = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(
        title: "Preview item",
        body: "Exercise overview mutations.",
        priority: .high,
        agentMode: .interactive,
        tags: ["preview"],
        projectId: "project-preview"
      )
    )
    #expect(created.status == .todo)

    let moved = try await client.updateTaskBoardItem(
      id: created.id,
      request: TaskBoardUpdateItemRequest(status: .todo)
    )
    #expect(moved.status == .todo)

    let dispatch = try await client.dispatchTaskBoard(
      request: TaskBoardDispatchRequest(itemId: created.id, dryRun: false)
    )
    #expect(dispatch.applied.map(\.boardItemId) == [created.id])

    let dispatched = try await client.taskBoardItem(id: created.id)
    #expect(dispatched.status == .inProgress)
    #expect(dispatched.sessionId == "preview-session-\(created.id)")
    #expect(dispatched.workItemId == "preview-task-\(created.id)")

    let evaluation = try await client.evaluateTaskBoard(
      request: TaskBoardEvaluateRequest(itemId: created.id, dryRun: false)
    )
    #expect(evaluation.total == 1)
    #expect(evaluation.updated == 1)
    let evaluated = try await client.taskBoardItem(id: created.id)
    #expect(evaluated.status == .toReview)

    let run = try await client.runTaskBoardOrchestratorOnce(
      request: TaskBoardOrchestratorRunOnceRequest(itemId: created.id)
    )
    let runRecordIDs = run.lastRun?.evaluation?.records.map(\.boardItemId)
    #expect(runRecordIDs == [created.id])
    #expect(run.lastRun?.dryRun == false)

    let deleted = try await client.deleteTaskBoardItem(id: created.id)
    #expect(deleted.id == created.id)
    let remaining = try await client.taskBoardItems(status: nil)
    #expect(remaining.contains { $0.id == created.id } == false)
  }

  @Test("Preview client returns planning transitions")
  func previewClientReturnsPlanningTransitions() async throws {
    let client = PreviewHarnessClient(
      fixtures: .taskBoardBoardOnly,
      isLaunchAgentInstalled: true
    )
    let items = try await client.taskBoardItems(status: nil)
    let item = try #require(items.first)

    let planning = try await client.beginTaskBoardPlan(id: item.id)
    #expect(planning.transition.fromStatus == .todo)
    #expect(planning.transition.toStatus == .planning)
    #expect(planning.item.status == .planning)

    let submitted = try await client.submitTaskBoardPlan(
      id: item.id,
      request: TaskBoardPlanSubmitRequest(summary: "Plan ready")
    )
    #expect(submitted.item.status == .planReview)
    #expect(submitted.item.planning.summary == "Plan ready")

    let approved = try await client.approveTaskBoardPlan(
      id: item.id,
      request: TaskBoardPlanApproveRequest(approvedBy: "preview-user")
    )
    #expect(approved.item.status == .todo)
    #expect(approved.item.planning.approvedBy == "preview-user")
  }

  @Test("Preview client applies a CAS position set and reset")
  func previewClientAppliesPositionMutations() async throws {
    let client = PreviewHarnessClient(fixtures: .taskBoardBoardOnly, isLaunchAgentInstalled: true)
    let item = try #require(try await client.taskBoardItems(status: .backlog).first)
    let before = try await client.taskBoardItemPositionSnapshot(id: item.id)
    let set = try await client.setTaskBoardItemPosition(
      id: item.id,
      request: TaskBoardSetItemPositionRequest(
        status: .todo, lanePosition: 0, expectedItemRevision: before.itemRevision,
        expectedItemsChangeSeq: before.itemsChangeSeq
      )
    )
    #expect(set.snapshot.item.lanePosition == 0)
    let reset = try await client.resetTaskBoardItemPosition(
      id: item.id,
      request: TaskBoardResetItemPositionRequest(
        expectedItemRevision: set.snapshot.itemRevision,
        expectedItemsChangeSeq: set.snapshot.itemsChangeSeq
      )
    )
    #expect(reset.snapshot.item.lanePosition == nil)
  }

  @Test("Preview positions compact source and reset lanes with one sequence per mutation")
  func previewPositionMutationsCompactSourceAndResetLanes() async throws {
    let client = PreviewHarnessClient(fixtures: .taskBoardBoardOnly, isLaunchAgentInstalled: true)
    var created: [TaskBoardItem] = []
    for title in ["a", "b", "c"] {
      created.append(
        try await client.createTaskBoardItem(request: TaskBoardCreateItemRequest(title: title)))
    }
    for (slot, item) in created.enumerated() {
      let snapshot = try await client.taskBoardItemPositionSnapshot(id: item.id)
      _ = try await client.setTaskBoardItemPosition(
        id: item.id,
        request: TaskBoardSetItemPositionRequest(
          status: .todo, lanePosition: UInt32(slot), expectedItemRevision: snapshot.itemRevision,
          expectedItemsChangeSeq: snapshot.itemsChangeSeq
        )
      )
    }
    let beforeMove = try await client.taskBoardItemPositionSnapshot(id: created[0].id)
    let moved = try await client.setTaskBoardItemPosition(
      id: created[0].id,
      request: TaskBoardSetItemPositionRequest(
        status: .planning, lanePosition: 0, expectedItemRevision: beforeMove.itemRevision,
        expectedItemsChangeSeq: beforeMove.itemsChangeSeq
      )
    )
    #expect(moved.snapshot.itemsChangeSeq == beforeMove.itemsChangeSeq + 1)
    let secondAfterMove = try await client.taskBoardItem(id: created[1].id)
    let thirdAfterMove = try await client.taskBoardItem(id: created[2].id)
    #expect(secondAfterMove.lanePosition == 0)
    #expect(thirdAfterMove.lanePosition == 1)

    let beforeReset = try await client.taskBoardItemPositionSnapshot(id: created[1].id)
    let reset = try await client.resetTaskBoardItemPosition(
      id: created[1].id,
      request: TaskBoardResetItemPositionRequest(
        expectedItemRevision: beforeReset.itemRevision,
        expectedItemsChangeSeq: beforeReset.itemsChangeSeq
      )
    )
    #expect(reset.snapshot.itemsChangeSeq == beforeReset.itemsChangeSeq + 1)
    let thirdAfterReset = try await client.taskBoardItem(id: created[2].id)
    #expect(thirdAfterReset.lanePosition == 0)
  }

  @Test("Preview position set compacts a materialized default source slot")
  func previewPositionSetCompactsMaterializedDefaultSourceSlot() async throws {
    let client = PreviewHarnessClient(fixtures: .taskBoardBoardOnly, isLaunchAgentInstalled: true)
    let source = try #require(try await client.taskBoardItems(status: .backlog).first)
    let sourceAnchor = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(title: "Source anchor")
    )
    let sourceAnchorSnapshot = try await client.taskBoardItemPositionSnapshot(id: sourceAnchor.id)
    _ = try await client.setTaskBoardItemPosition(
      id: sourceAnchor.id,
      request: TaskBoardSetItemPositionRequest(
        status: .backlog, lanePosition: 1,
        expectedItemRevision: sourceAnchorSnapshot.itemRevision,
        expectedItemsChangeSeq: sourceAnchorSnapshot.itemsChangeSeq
      )
    )
    let destinationAnchor = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(title: "Destination anchor")
    )
    let destinationAnchorSnapshot = try await client.taskBoardItemPositionSnapshot(
      id: destinationAnchor.id
    )
    _ = try await client.setTaskBoardItemPosition(
      id: destinationAnchor.id,
      request: TaskBoardSetItemPositionRequest(
        status: .planning, lanePosition: 0,
        expectedItemRevision: destinationAnchorSnapshot.itemRevision,
        expectedItemsChangeSeq: destinationAnchorSnapshot.itemsChangeSeq
      )
    )
    let unrelatedAnchor = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(title: "Unrelated anchor")
    )
    let unrelatedAnchorSnapshot = try await client.taskBoardItemPositionSnapshot(
      id: unrelatedAnchor.id
    )
    _ = try await client.setTaskBoardItemPosition(
      id: unrelatedAnchor.id,
      request: TaskBoardSetItemPositionRequest(
        status: .inProgress, lanePosition: 0,
        expectedItemRevision: unrelatedAnchorSnapshot.itemRevision,
        expectedItemsChangeSeq: unrelatedAnchorSnapshot.itemsChangeSeq
      )
    )

    let sourceSnapshot = try await client.taskBoardItemPositionSnapshot(id: source.id)
    _ = try await client.setTaskBoardItemPosition(
      id: source.id,
      request: TaskBoardSetItemPositionRequest(
        status: .planning, lanePosition: 0,
        expectedItemRevision: sourceSnapshot.itemRevision,
        expectedItemsChangeSeq: sourceSnapshot.itemsChangeSeq
      )
    )

    let sourceAfterMove = try await client.taskBoardItem(id: sourceAnchor.id)
    let destinationAfterMove = try await client.taskBoardItem(id: destinationAnchor.id)
    let unrelatedAfterMove = try await client.taskBoardItem(id: unrelatedAnchor.id)
    #expect(sourceAfterMove.lanePosition == 0)
    #expect(destinationAfterMove.lanePosition == 1)
    #expect(unrelatedAfterMove.lanePosition == 0)
  }

  @Test("Preview list and snapshot materialize canonical lane order")
  func previewPositionListAndSnapshotUseCanonicalMaterializedLaneOrder() async throws {
    let client = PreviewHarnessClient(fixtures: .taskBoardBoardOnly, isLaunchAgentInstalled: true)
    let higherPriority = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(title: "Higher priority", priority: .high)
    )
    let lowerPriority = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(title: "Lower priority", priority: .low)
    )
    let position = try await client.taskBoardItemPositionSnapshot(id: lowerPriority.id)
    _ = try await client.setTaskBoardItemPosition(
      id: lowerPriority.id,
      request: TaskBoardSetItemPositionRequest(
        status: .todo, lanePosition: 0, expectedItemRevision: position.itemRevision,
        expectedItemsChangeSeq: position.itemsChangeSeq
      )
    )

    let list = try await client.taskBoardItems(status: .todo)
    let snapshot = try await client.taskBoardItemsSnapshot(status: .todo)
    #expect(list.first?.id == lowerPriority.id)
    #expect(snapshot.items.first?.id == lowerPriority.id)
    #expect(list.map(\.id) == snapshot.items.map(\.id))
    let lowerIndex = try #require(list.firstIndex(where: { $0.id == lowerPriority.id }))
    let higherIndex = try #require(list.firstIndex(where: { $0.id == higherPriority.id }))
    #expect(lowerIndex < higherIndex)
  }

  @Test("Preview position set compacts same-lane slots in both directions")
  func previewPositionSetCompactsSameLaneSlotsInBothDirections() async throws {
    let client = PreviewHarnessClient(fixtures: .taskBoardBoardOnly, isLaunchAgentInstalled: true)
    var items: [TaskBoardItem] = []
    for title in ["a", "b", "c"] {
      items.append(
        try await client.createTaskBoardItem(request: TaskBoardCreateItemRequest(title: title)))
    }
    for (slot, item) in items.enumerated() {
      let snapshot = try await client.taskBoardItemPositionSnapshot(id: item.id)
      _ = try await client.setTaskBoardItemPosition(
        id: item.id,
        request: TaskBoardSetItemPositionRequest(
          status: .todo, lanePosition: UInt32(slot), expectedItemRevision: snapshot.itemRevision,
          expectedItemsChangeSeq: snapshot.itemsChangeSeq, actor: "initial-position"
        )
      )
    }
    let unrelated = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(title: "Unrelated lane")
    )
    let unrelatedSnapshot = try await client.taskBoardItemPositionSnapshot(id: unrelated.id)
    _ = try await client.setTaskBoardItemPosition(
      id: unrelated.id,
      request: TaskBoardSetItemPositionRequest(
        status: .planning, lanePosition: 0, expectedItemRevision: unrelatedSnapshot.itemRevision,
        expectedItemsChangeSeq: unrelatedSnapshot.itemsChangeSeq, actor: "unrelated-position"
      )
    )
    let beforeForward = try await client.taskBoardItemPositionSnapshot(id: items[0].id)
    let shiftedBeforeForward = try await client.taskBoardItem(id: items[1].id)
    _ = try await client.setTaskBoardItemPosition(
      id: items[0].id,
      request: TaskBoardSetItemPositionRequest(
        status: .todo, lanePosition: 2, expectedItemRevision: beforeForward.itemRevision,
        expectedItemsChangeSeq: beforeForward.itemsChangeSeq, actor: "forward-actor"
      )
    )
    let firstAfterForward = try await client.taskBoardItem(id: items[0].id)
    let secondAfterForward = try await client.taskBoardItem(id: items[1].id)
    let thirdAfterForward = try await client.taskBoardItem(id: items[2].id)
    #expect(firstAfterForward.lanePosition == 2)
    #expect(firstAfterForward.laneOrigin == .manual(actor: "forward-actor"))
    #expect(secondAfterForward.lanePosition == 0)
    #expect(thirdAfterForward.lanePosition == 1)
    #expect(secondAfterForward.laneOrigin == shiftedBeforeForward.laneOrigin)
    #expect(secondAfterForward.laneSetAt == shiftedBeforeForward.laneSetAt)
    #expect(secondAfterForward.updatedAt == shiftedBeforeForward.updatedAt)
    #expect((try await client.taskBoardItem(id: unrelated.id)).lanePosition == 0)

    let beforeBackward = try await client.taskBoardItemPositionSnapshot(id: items[0].id)
    _ = try await client.setTaskBoardItemPosition(
      id: items[0].id,
      request: TaskBoardSetItemPositionRequest(
        status: .todo, lanePosition: 0, expectedItemRevision: beforeBackward.itemRevision,
        expectedItemsChangeSeq: beforeBackward.itemsChangeSeq, actor: "backward-actor"
      )
    )
    #expect((try await client.taskBoardItem(id: items[0].id)).lanePosition == 0)
    #expect(
      (try await client.taskBoardItem(id: items[0].id)).laneOrigin
        == .manual(actor: "backward-actor"))
    #expect((try await client.taskBoardItem(id: items[1].id)).lanePosition == 1)
    #expect((try await client.taskBoardItem(id: items[2].id)).lanePosition == 2)
    #expect((try await client.taskBoardItem(id: unrelated.id)).lanePosition == 0)
  }

  @Test("Preview position reset rejects default placement with the public state error")
  func previewPositionResetRejectsDefaultPlacement() async throws {
    let client = PreviewHarnessClient(fixtures: .taskBoardBoardOnly, isLaunchAgentInstalled: true)
    let item = try #require(try await client.taskBoardItems(status: .backlog).first)
    let snapshot = try await client.taskBoardItemPositionSnapshot(id: item.id)

    do {
      _ = try await client.resetTaskBoardItemPosition(
        id: item.id,
        request: TaskBoardResetItemPositionRequest(
          expectedItemRevision: snapshot.itemRevision,
          expectedItemsChangeSeq: snapshot.itemsChangeSeq
        )
      )
      Issue.record("Expected default placement reset to fail")
    } catch let error as HarnessMonitorAPIError {
      #expect(error == .server(code: 400, message: "Task board item has no explicit position"))
    }
  }

  @Test("Preview non-position updates preserve placement metadata")
  func previewNonPositionUpdatePreservesPlacementMetadata() {
    let item = taskBoardItem(
      externalRefs: [],
      lanePosition: 3,
      laneOrigin: .manual(actor: "daemon-control"),
      laneSetAt: "2026-07-22T14:00:00Z"
    )
    let updated = item.applyingPreviewUpdate(TaskBoardUpdateItemRequest(priority: .critical))

    #expect(updated.lanePosition == 3)
    #expect(updated.laneOrigin == .manual(actor: "daemon-control"))
    #expect(updated.laneSetAt == "2026-07-22T14:00:00Z")
  }

  @Test("Preview client returns task board audit and catalog summaries")
  func previewClientReturnsTaskBoardAuditAndCatalogSummaries() async throws {
    let client = PreviewHarnessClient(
      fixtures: .taskBoardBoardOnly,
      isLaunchAgentInstalled: true
    )

    let audit = try await client.auditTaskBoard(status: nil)
    let projects = try await client.taskBoardProjects(status: nil)
    let machines = try await client.taskBoardMachines(status: nil)

    #expect(audit.total >= 1)
    #expect(audit.ready >= 1)
    #expect(!projects.isEmpty)
    #expect(!machines.isEmpty)
  }

  @Test("Preview external ref replacement preserves matching stored sync state")
  func previewExternalRefReplacementPreservesMatchingStoredSyncState() throws {
    let storedSyncState = TaskBoardExternalRefSyncState(status: .done)
    let item = taskBoardItem(
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "example/project#42",
          url: "https://github.com/example/project/pull/42",
          syncState: storedSyncState
        )
      ]
    )

    let updated = item.applyingPreviewUpdate(
      TaskBoardUpdateItemRequest(
        externalRefs: [
          TaskBoardExternalRef(
            provider: .gitHub,
            externalId: "example/project#42",
            url: "https://github.com/example/project/pull/42?view=files",
            syncState: TaskBoardExternalRefSyncState(status: .todo)
          )
        ]
      )
    )
    let replacement = try #require(updated.externalRefs.first)

    #expect(replacement.url == "https://github.com/example/project/pull/42?view=files")
    #expect(replacement.syncState == storedSyncState)
  }

  @Test("Preview external ref replacement rejects sync state for new identities")
  func previewExternalRefReplacementRejectsNewIdentitySyncState() {
    let item = taskBoardItem(
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "example/project#42",
          syncState: TaskBoardExternalRefSyncState(status: .done)
        )
      ]
    )
    let clientSyncState = TaskBoardExternalRefSyncState(status: .todo)

    let updated = item.applyingPreviewUpdate(
      TaskBoardUpdateItemRequest(
        externalRefs: [
          TaskBoardExternalRef(
            provider: .todoist,
            externalId: "example/project#42",
            syncState: clientSyncState
          ),
          TaskBoardExternalRef(
            provider: .gitHub,
            externalId: "EXAMPLE/PROJECT#42",
            syncState: clientSyncState
          ),
          TaskBoardExternalRef(
            provider: .gitHub,
            externalId: "example/project#43",
            syncState: clientSyncState
          ),
        ]
      )
    )

    #expect(updated.externalRefs.count == 3)
    #expect(updated.externalRefs.allSatisfy { $0.syncState == nil })
  }

  @Test("Preview external ref replacement distinguishes nil from empty")
  func previewExternalRefReplacementDistinguishesNilFromEmpty() {
    let refs = [
      TaskBoardExternalRef(
        provider: .gitHub,
        externalId: "example/project#42",
        syncState: TaskBoardExternalRefSyncState(status: .done)
      )
    ]
    let item = taskBoardItem(externalRefs: refs)

    let unchanged = item.applyingPreviewUpdate(TaskBoardUpdateItemRequest(status: .inProgress))
    let cleared = item.applyingPreviewUpdate(TaskBoardUpdateItemRequest(externalRefs: []))

    #expect(unchanged.externalRefs == refs)
    #expect(cleared.externalRefs.isEmpty)
  }

  private func taskBoardItem(
    externalRefs: [TaskBoardExternalRef],
    lanePosition: UInt32? = nil,
    laneOrigin: TaskBoardLaneOrigin? = nil,
    laneSetAt: String? = nil
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: "preview-external-ref-item",
      title: "Preview item",
      body: "Body",
      status: .todo,
      priority: .medium,
      tags: [],
      projectId: "example/project",
      agentMode: .interactive,
      externalRefs: externalRefs,
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      lanePosition: lanePosition,
      laneOrigin: laneOrigin,
      laneSetAt: laneSetAt,
      createdAt: "2026-07-13T10:00:00Z",
      updatedAt: "2026-07-13T10:01:00Z",
      deletedAt: nil
    )
  }
}
