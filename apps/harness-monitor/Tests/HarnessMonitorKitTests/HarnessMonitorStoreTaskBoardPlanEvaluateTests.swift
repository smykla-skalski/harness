import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board plan revoke and evaluate preview")
struct HarnessMonitorStoreTaskBoardPlanEvaluateTests {
  @Test("Revoke task board plan records the actor and reports success")
  func revokeTaskBoardPlanRecordsActor() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([sampleTaskBoardItem()])
    let store = await makeBootstrappedStore(client: client)

    let success = await store.revokeTaskBoardPlan(id: "board-1", actor: "reviewer")

    #expect(success)
    #expect(
      client.recordedCalls().contains(
        .revokeTaskBoardPlan(id: "board-1", actor: "reviewer")
      )
    )
    #expect(store.currentSuccessFeedbackMessage == "Revoked task board plan")
  }

  @Test("Preview evaluate returns counts without mutating the persisted summary")
  func previewEvaluateReturnsCountsWithoutMutatingState() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)

    let summary = await store.previewEvaluateTaskBoard(status: .todo)

    #expect(summary != nil)
    #expect(
      client.recordedCalls().contains(
        .evaluateTaskBoard(dryRun: true, status: .todo, itemID: nil)
      )
    )
    #expect(store.globalTaskBoardEvaluationSummary == nil)
    #expect(store.currentSuccessFeedbackMessage == "Previewed task board evaluate")
  }

  private func sampleTaskBoardItem(id: String = "board-1") -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Board item",
      body: "Body",
      status: .todo,
      priority: .high,
      tags: ["automation"],
      projectId: "project-1",
      agentMode: .interactive,
      externalRefs: [],
      planning: TaskBoardPlanningState(summary: "Approved plan"),
      workflow: nil,
      sessionId: "sess-1",
      workItemId: "task-1",
      usage: TaskBoardUsage(),
      createdAt: "2026-05-14T10:00:00Z",
      updatedAt: "2026-05-14T10:01:00Z",
      deletedAt: nil
    )
  }
}
