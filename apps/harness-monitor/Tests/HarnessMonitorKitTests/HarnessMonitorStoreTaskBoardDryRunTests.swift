import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board Dry Run")
struct HarnessMonitorStoreTaskBoardDryRunTests {
  @Test("Applies the authoritative dry-run setting without a dashboard refresh")
  func appliesAuthoritativeDryRunSettingWithoutDashboardRefresh() async throws {
    let client = RecordingHarnessClient()
    let authoritativeSettings = client.sampleTaskBoardOrchestratorSettings(
      dryRunDefault: true,
      policyVersion: "task-board-policy-dry-run"
    )
    client.configureTaskBoardOrchestratorSettingsResponse(authoritativeSettings)
    let store = await makeBootstrappedStore(client: client)
    let baselineReads = taskBoardReadCounts(client)

    let success = await store.setTaskBoardDryRunDefault(enabled: true)

    #expect(success)
    let globalStatus = try #require(store.globalTaskBoardOrchestratorStatus)
    let presentedStatus = try #require(store.contentUI.dashboard.taskBoardOrchestratorStatus)
    #expect(globalStatus.settings == authoritativeSettings)
    #expect(presentedStatus.settings == authoritativeSettings)
    #expect(taskBoardReadCounts(client) == baselineReads)
    #expect(recordedDryRunMutations(client) == [true])
    #expect(store.currentSuccessFeedbackMessage == nil)
    #expect(!store.isDaemonActionInFlight)
  }

  private func taskBoardReadCounts(_ client: RecordingHarnessClient) -> [Int] {
    [
      client.readCallCount(.taskBoardItems(nil)),
      client.readCallCount(.taskBoardOrchestratorStatus),
    ]
  }

  private func recordedDryRunMutations(_ client: RecordingHarnessClient) -> [Bool] {
    client.recordedCalls().compactMap { call in
      guard case .updateTaskBoardOrchestratorSettings(_, let dryRun, _, _, _) = call else {
        return nil
      }
      return dryRun
    }
  }
}
