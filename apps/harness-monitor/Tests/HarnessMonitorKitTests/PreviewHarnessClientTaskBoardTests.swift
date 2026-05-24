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
    #expect(created.status == .new)

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
    #expect(evaluated.status == .inReview)

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
}
