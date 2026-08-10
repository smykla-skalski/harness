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

  @Test("Repeated ready cancels a dry-run mutation waiting for the settings lock")
  func repeatedReadyCancelsWaitingDryRunMutation() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.acquireTaskBoardOrchestratorSettingsMutationLock()
    let mutation = Task { @MainActor in
      await store.setTaskBoardDryRunDefault(enabled: true)
    }
    #expect(
      await waitUntil {
        store.taskBoardRuntimeState.orchestratorSettingsMutation.waiters.count == 1
      }
    )

    var hasSeenReady = true
    #expect(
      await store.processGlobalStreamEvent(
        DaemonPushEvent(recordedAt: "2026-08-10T00:00:00Z", sessionId: nil, kind: .ready),
        using: client,
        hasSeenReady: &hasSeenReady
      )
    )
    store.releaseTaskBoardOrchestratorSettingsMutationLock()

    #expect(await mutation.value == false)
    #expect(recordedDryRunMutations(client).isEmpty)
    await store.prepareForTermination()
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
