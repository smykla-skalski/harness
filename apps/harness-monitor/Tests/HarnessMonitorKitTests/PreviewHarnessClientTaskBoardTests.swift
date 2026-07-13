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

  private func taskBoardItem(externalRefs: [TaskBoardExternalRef]) -> TaskBoardItem {
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
      createdAt: "2026-07-13T10:00:00Z",
      updatedAt: "2026-07-13T10:01:00Z",
      deletedAt: nil
    )
  }
}
