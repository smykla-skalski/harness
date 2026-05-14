import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board dashboard")
struct HarnessMonitorStoreTaskBoardDashboardTests {
  @Test("Refresh task board dashboard hydrates board items")
  func refreshTaskBoardDashboardHydratesBoardItems() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([sampleTaskBoardItem()])
    let store = await makeBootstrappedStore(client: client)
    let baselineCalls = client.readCallCount(.taskBoardItems(nil))

    await store.refreshTaskBoardDashboard()

    #expect(client.readCallCount(.taskBoardItems(nil)) == baselineCalls + 1)
    #expect(store.globalTaskBoardItems.first?.id == "board-1")
    #expect(store.globalTaskBoardItems.first?.externalRefs.first?.provider == .gitHub)
    #expect(store.contentUI.dashboard.taskBoardItems.first?.id == "board-1")
  }

  @Test("Evaluate task board records the summary and refreshes dashboard state")
  func evaluateTaskBoardRecordsSummaryAndRefreshesDashboardState() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)

    let success = await store.evaluateTaskBoard(status: .inProgress, dryRun: true)

    #expect(success)
    #expect(
      client.recordedCalls().contains(
        .evaluateTaskBoard(dryRun: true, status: .inProgress)
      )
    )
    #expect(store.globalTaskBoardEvaluationSummary?.updated == 1)
    #expect(store.contentUI.dashboard.taskBoardEvaluationSummary?.updated == 1)
    #expect(store.currentSuccessFeedbackMessage == "Evaluated task board")
  }

  @Test("Moving a task board item updates status through the daemon")
  func movingTaskBoardItemUpdatesStatusThroughDaemon() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([sampleTaskBoardItem()])
    let store = await makeBootstrappedStore(client: client)

    let success = await store.updateTaskBoardItemStatus(id: "board-1", status: .inProgress)

    #expect(success)
    #expect(
      client.recordedCalls().contains(
        .updateTaskBoardItem(id: "board-1", status: .inProgress)
      )
    )
    #expect(store.globalTaskBoardItems.first?.status == .inProgress)
    #expect(store.contentUI.dashboard.taskBoardItems.first?.status == .inProgress)
    #expect(store.currentSuccessFeedbackMessage == "Moved task board item")
  }

  @Test("Run once forwards scoped board request and refreshes dashboard status")
  func runOnceForwardsScopedBoardRequestAndRefreshesDashboardStatus() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)

    let success = await store.runTaskBoardOrchestratorOnce(
      request: TaskBoardOrchestratorRunOnceRequest(
        dryRun: false,
        status: .todo,
        projectDir: "/tmp/harness"
      )
    )

    #expect(success)
    #expect(
      client.recordedCalls().contains(
        .runTaskBoardOrchestratorOnce(
          dryRun: false,
          status: .todo,
          projectDir: "/tmp/harness"
        )
      )
    )
    #expect(store.globalTaskBoardOrchestratorStatus?.enabled == true)
    #expect(store.contentUI.dashboard.taskBoardOrchestratorStatus?.enabled == true)
    #expect(store.currentSuccessFeedbackMessage == "Ran task board")
  }

  @Test("Start and stop orchestrator update dashboard status")
  func startAndStopOrchestratorUpdateDashboardStatus() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)

    let started = await store.startTaskBoardOrchestrator()
    let stopped = await store.stopTaskBoardOrchestrator()

    #expect(started)
    #expect(stopped)
    #expect(client.recordedCalls().contains(.startTaskBoardOrchestrator))
    #expect(client.recordedCalls().contains(.stopTaskBoardOrchestrator))
    #expect(store.globalTaskBoardOrchestratorStatus?.running == false)
    #expect(store.contentUI.dashboard.taskBoardOrchestratorStatus?.running == false)
    #expect(store.currentSuccessFeedbackMessage == "Stopped task board")
  }

  private func sampleTaskBoardItem() -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: "board-1",
      title: "Board item",
      body: "Body",
      status: .todo,
      priority: .high,
      tags: ["automation"],
      projectId: "project-1",
      agentMode: .interactive,
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "123",
          url: "https://example.invalid/issues/123"
        )
      ],
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
