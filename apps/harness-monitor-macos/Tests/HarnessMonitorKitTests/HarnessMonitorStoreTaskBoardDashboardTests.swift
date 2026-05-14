import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board dashboard")
struct HarnessMonitorStoreTaskBoardDashboardTests {
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
}
