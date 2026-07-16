import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board Step Mode")
struct HarnessMonitorStoreTaskBoardStepModeTests {
  @Test("Applies authoritative settings without a dashboard refresh")
  func appliesAuthoritativeSettingsWithoutDashboardRefresh() async throws {
    let client = RecordingHarnessClient()
    let authoritativeSettings = client.sampleTaskBoardOrchestratorSettings(
      stepMode: true,
      policyVersion: "task-board-policy-authoritative"
    )
    client.configureTaskBoardOrchestratorSettingsResponse(authoritativeSettings)
    let store = await makeBootstrappedStore(client: client)
    let baselineReads = taskBoardReadCounts(client)

    let success = await store.setTaskBoardStepMode(enabled: true)

    #expect(success)
    try expectPresentedSettings(store, equal: authoritativeSettings)
    #expect(taskBoardReadCounts(client) == baselineReads)
    #expect(recordedStepModeMutations(client) == [true])
    #expect(!store.isDaemonActionInFlight)
  }

  @Test("Failure rolls back to the last authoritative settings")
  func failureRollsBackToLastAuthoritativeSettings() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    let baselineReads = taskBoardReadCounts(client)

    #expect(await store.setTaskBoardStepMode(enabled: true))
    let lastAuthoritativeSettings = try #require(
      store.globalTaskBoardOrchestratorStatus?.settings
    )
    client.configureTaskBoardOrchestratorSettingsError(
      HarnessMonitorAPIError.server(code: 503, message: "Step Mode unavailable.")
    )

    let success = await store.setTaskBoardStepMode(enabled: false)

    #expect(!success)
    try expectPresentedSettings(store, equal: lastAuthoritativeSettings)
    #expect(store.globalTaskBoardOrchestratorStatus?.stepMode == true)
    #expect(taskBoardReadCounts(client) == baselineReads)
    #expect(recordedStepModeMutations(client) == [true, false])
    #expect(store.currentFailureFeedbackMessage?.contains("Step Mode unavailable") == true)
    #expect(!store.isDaemonActionInFlight)
  }

  @Test("A stale dashboard refresh cannot overwrite confirmed Step Mode")
  func staleDashboardRefreshCannotOverwriteConfirmedStepMode() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    let staleStatus = client.sampleTaskBoardOrchestratorStatus(stepMode: false)
    let staleSnapshot = taskBoardSnapshot(
      status: staleStatus,
      confirmationRevision: store.taskBoardRuntimeState.stepModeMutation.confirmationRevision
    )

    #expect(await store.setTaskBoardStepMode(enabled: true))
    store.applyTaskBoardDashboardSnapshot(staleSnapshot)

    let confirmedSettings = try #require(
      store.globalTaskBoardOrchestratorStatus?.settings
    )
    #expect(confirmedSettings.stepMode)
    try expectPresentedSettings(store, equal: confirmedSettings)

    let freshSnapshot = taskBoardSnapshot(
      status: staleStatus,
      confirmationRevision: store.taskBoardRuntimeState.stepModeMutation.confirmationRevision
    )
    store.applyTaskBoardDashboardSnapshot(freshSnapshot)
    #expect(store.globalTaskBoardOrchestratorStatus?.stepMode == false)
  }

  @Test("Rapid enable then disable ignores the stale enable completion")
  func rapidEnableThenDisableIgnoresStaleEnableCompletion() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    let baselineReads = taskBoardReadCounts(client)
    await client.blockNextTaskBoardOrchestratorSettingsMutations()

    let enableTask = Task { @MainActor in
      await store.setTaskBoardStepMode(enabled: true)
    }
    await client.waitForBlockedTaskBoardOrchestratorSettingsMutations()
    let disableTask = Task { @MainActor in
      await store.setTaskBoardStepMode(enabled: false)
    }
    #expect(await waitForMutationGeneration(2, store: store))

    await client.releaseNextTaskBoardOrchestratorSettingsMutation()
    #expect(await enableTask.value)
    #expect(await disableTask.value)

    let settings = try #require(store.globalTaskBoardOrchestratorStatus?.settings)
    #expect(!settings.stepMode)
    try expectPresentedSettings(store, equal: settings)
    #expect(recordedStepModeMutations(client) == [true, false])
    #expect(taskBoardReadCounts(client) == baselineReads)
    #expect(!store.isDaemonActionInFlight)
  }

  @Test("Rapid enable disable enable coalesces stale intermediate intent")
  func rapidEnableDisableEnableCoalescesStaleIntermediateIntent() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    let baselineReads = taskBoardReadCounts(client)
    await client.blockNextTaskBoardOrchestratorSettingsMutations()

    let firstEnableTask = Task { @MainActor in
      await store.setTaskBoardStepMode(enabled: true)
    }
    await client.waitForBlockedTaskBoardOrchestratorSettingsMutations()
    let disableTask = Task { @MainActor in
      await store.setTaskBoardStepMode(enabled: false)
    }
    #expect(await waitForMutationGeneration(2, store: store))
    let finalEnableTask = Task { @MainActor in
      await store.setTaskBoardStepMode(enabled: true)
    }
    #expect(await waitForMutationGeneration(3, store: store))

    await client.releaseNextTaskBoardOrchestratorSettingsMutation()
    #expect(await firstEnableTask.value)
    #expect(await disableTask.value)
    #expect(await finalEnableTask.value)

    let settings = try #require(store.globalTaskBoardOrchestratorStatus?.settings)
    #expect(settings.stepMode)
    try expectPresentedSettings(store, equal: settings)
    #expect(recordedStepModeMutations(client) == [true])
    #expect(taskBoardReadCounts(client) == baselineReads)
    #expect(!store.isDaemonActionInFlight)
  }

  private func taskBoardReadCounts(_ client: RecordingHarnessClient) -> [Int] {
    [
      client.readCallCount(.taskBoardItems(nil)),
      client.readCallCount(.taskBoardOrchestratorStatus),
    ]
  }

  private func recordedStepModeMutations(_ client: RecordingHarnessClient) -> [Bool] {
    client.recordedCalls().compactMap { call in
      guard case .updateTaskBoardOrchestratorSettings(let stepMode, _, _, _) = call else {
        return nil
      }
      return stepMode
    }
  }

  private func taskBoardSnapshot(
    status: TaskBoardOrchestratorStatus,
    confirmationRevision: UInt64
  ) -> HarnessMonitorStore.TaskBoardRefreshSnapshot {
    HarnessMonitorStore.TaskBoardRefreshSnapshot(
      items: HarnessMonitorStore.TaskBoardSnapshotLoad<[TaskBoardItem]>(measured: nil),
      orchestratorStatus: HarnessMonitorStore.TaskBoardSnapshotLoad(
        measured: HarnessMonitorStore.MeasuredOperation(
          value: Optional(status),
          latencyMs: 0
        )
      ),
      stepModeConfirmationRevision: confirmationRevision
    )
  }

  private func expectPresentedSettings(
    _ store: HarnessMonitorStore,
    equal expected: TaskBoardOrchestratorSettings
  ) throws {
    let globalStatus = try #require(store.globalTaskBoardOrchestratorStatus)
    let presentedStatus = try #require(
      store.contentUI.dashboard.taskBoardOrchestratorStatus
    )
    #expect(globalStatus.stepMode == expected.stepMode)
    #expect(globalStatus.settings == expected)
    #expect(presentedStatus.stepMode == expected.stepMode)
    #expect(presentedStatus.settings == expected)
  }

  private func waitForMutationGeneration(
    _ generation: UInt64,
    store: HarnessMonitorStore
  ) async -> Bool {
    for _ in 0..<10_000 {
      if store.taskBoardRuntimeState.stepModeMutation.latestGeneration >= generation {
        return true
      }
      await Task.yield()
    }
    return false
  }
}
