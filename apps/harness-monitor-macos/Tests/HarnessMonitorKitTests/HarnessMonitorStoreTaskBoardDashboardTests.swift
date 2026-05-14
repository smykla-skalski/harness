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
}
