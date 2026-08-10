import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreTaskBoardSettingsTests {
  @Test("Repeated ready rejects an older in-flight capability result")
  func repeatedReadyRejectsOlderInFlightCapabilityResult() async {
    let staleCapabilitiesGate = LegacyContainmentCapabilitiesGate()
    let replacementCapabilitiesGate = LegacyContainmentVoidGate()
    let client = RecordingHarnessClient()
    let store = connectedTaskBoardStore(client: client)
    store.adoptDatabaseBackedTaskBoard(client.taskBoardCapabilitiesValue)
    client.taskBoardCapabilitiesHandler = { await staleCapabilitiesGate.wait() }
    let staleReadResult = RecordingTaskBoardOperationResult<Bool>()
    let staleRead = Task { @MainActor in
      do {
        _ = try await store.taskBoardHostSnapshot()
        await staleReadResult.record(true)
      } catch {
        await staleReadResult.record(false)
      }
    }

    guard await waitUntil({ await staleCapabilitiesGate.hasEntered }) else {
      staleRead.cancel()
      await staleCapabilitiesGate.release()
      Issue.record("Expected the stale Task Board read to request capabilities")
      return
    }
    client.taskBoardCapabilitiesHandler = {
      await replacementCapabilitiesGate.wait()
      return TaskBoardCapabilities(
        storage: "database",
        revision: 2,
        instanceID: "task-board-b"
      )
    }
    let recoveryResult = RecordingTaskBoardOperationResult<Bool>()
    let recovery = Task { @MainActor in
      var hasSeenReady = true
      let result = await store.processGlobalStreamEvent(
        DaemonPushEvent(recordedAt: "2026-08-10T00:00:00Z", sessionId: nil, kind: .ready),
        using: client,
        hasSeenReady: &hasSeenReady
      )
      await recoveryResult.record(result)
    }

    guard await waitUntil({ await replacementCapabilitiesGate.hasEntered }) else {
      staleRead.cancel()
      recovery.cancel()
      await staleCapabilitiesGate.release()
      await replacementCapabilitiesGate.release()
      Issue.record("Expected repeated-ready synchronization to request capabilities")
      return
    }
    #expect(store.taskBoardDatabaseInstanceID == nil)
    await staleCapabilitiesGate.release()
    #expect(await waitUntil({ await staleReadResult.value != nil }))
    #expect(await staleReadResult.value == false)
    #expect(store.taskBoardDatabaseInstanceID == nil)

    client.taskBoardCapabilitiesValue = TaskBoardCapabilities(
      storage: "database",
      revision: 2,
      instanceID: "task-board-b"
    )
    client.taskBoardCapabilitiesHandler = nil
    await replacementCapabilitiesGate.release()
    #expect(await waitUntil({ await recoveryResult.value != nil }))
    #expect(await recoveryResult.value == true)
    #expect(store.taskBoardDatabaseInstanceID == "task-board-b")
    await store.prepareForTermination()
  }

  @Test("Repeated ready revokes in-flight access before database synchronization")
  func repeatedReadyRevokesAccessBeforeDatabaseSynchronization() async throws {
    let capabilitiesGate = LegacyContainmentVoidGate()
    let client = RecordingHarnessClient()
    let store = connectedTaskBoardStore(client: client)
    client.taskBoardCapabilitiesValue = TaskBoardCapabilities(
      storage: "database",
      revision: 1,
      instanceID: "task-board-a"
    )
    store.adoptDatabaseBackedTaskBoard(client.taskBoardCapabilitiesValue)
    await client.blockNextTaskBoardOrchestratorSettingsMutations()
    let staleSaveResult = RecordingTaskBoardOperationResult<Bool>()
    let staleSave = Task { @MainActor in
      let result = await store.updateTaskBoardGitSettings(
        snapshot: makeSettingsSnapshot(),
        origin: .settingsSecretsSaveButton
      )
      await staleSaveResult.record(result)
    }
    guard await client.waitForBlockedTaskBoardOrchestratorSettingsMutations() else {
      staleSave.cancel()
      Issue.record("Expected the stale settings save to reach the daemon mutation")
      return
    }
    client.taskBoardCapabilitiesHandler = {
      await capabilitiesGate.wait()
      return TaskBoardCapabilities(
        storage: "database",
        revision: 2,
        instanceID: "task-board-b"
      )
    }
    let recoveryResult = RecordingTaskBoardOperationResult<Bool>()
    let recovery = Task { @MainActor in
      var hasSeenReady = true
      let result = await store.processGlobalStreamEvent(
        DaemonPushEvent(recordedAt: "2026-08-10T00:00:00Z", sessionId: nil, kind: .ready),
        using: client,
        hasSeenReady: &hasSeenReady
      )
      await recoveryResult.record(result)
    }

    guard await waitUntil({ await capabilitiesGate.hasEntered }) else {
      staleSave.cancel()
      recovery.cancel()
      await client.releaseNextTaskBoardOrchestratorSettingsMutation()
      Issue.record("Expected repeated-ready synchronization to read database capabilities")
      return
    }
    #expect(store.taskBoardDatabaseInstanceID == nil)
    let concurrentSaveResult = RecordingTaskBoardOperationResult<Bool>()
    let concurrentSave = Task { @MainActor in
      let result = await store.updateTaskBoardGitSettings(
        snapshot: makeSettingsSnapshot(),
        origin: .settingsSecretsSaveButton
      )
      await concurrentSaveResult.record(result)
    }
    let concurrentTriageMutation = await store.setTaskBoardItemTriageOverride(
      id: "task-during-sync",
      verdict: .todo,
      reason: nil
    )
    #expect(concurrentTriageMutation == false)
    #expect(client.taskBoardTriageOverrideSetRequests.isEmpty)
    await client.releaseNextTaskBoardOrchestratorSettingsMutation()
    #expect(await waitUntil({ await staleSaveResult.value != nil }))
    #expect(await staleSaveResult.value == false)
    #expect(await waitUntil({ await concurrentSaveResult.value != nil }))
    #expect(await concurrentSaveResult.value == false)
    concurrentSave.cancel()
    client.taskBoardCapabilitiesValue = TaskBoardCapabilities(
      storage: "database",
      revision: 2,
      instanceID: "task-board-b"
    )
    client.taskBoardCapabilitiesHandler = nil
    await capabilitiesGate.release()
    #expect(await waitUntil({ await recoveryResult.value != nil }))
    #expect(await recoveryResult.value == true)

    #expect(store.taskBoardDatabaseInstanceID == "task-board-b")
    #expect(
      client.recordedCalls().contains {
        if case .updateTaskBoardGitRuntimeConfig = $0 { return true }
        return false
      } == false
    )
    await store.prepareForTermination()
  }

  @Test("Post-save work cannot publish after daemon replacement")
  func postSaveWorkCannotPublishAfterDaemonReplacement() async throws {
    let signingGate = LegacyContainmentVoidGate()
    let staleClient = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: staleClient)
    staleClient.taskBoardGitSigningVerifyHandler = {
      await signingGate.wait()
      return .failed(message: "stale signing failure")
    }
    staleClient.configureTaskBoardItems([taskBoardItem(id: "stale")])
    await staleClient.blockNextTaskBoardItemsRead()

    let settings = makeSettingsSnapshot()
    let saved = await store.updateTaskBoardGitSettings(
      snapshot: TaskBoardGitSettingsSnapshot(
        orchestratorSettings: settings.orchestratorSettings,
        runtimeConfig: settings.runtimeConfig,
        githubCredentials: TaskBoardGitHubCredentialSnapshot()
      ),
      origin: .settingsSecretsSaveButton
    )
    #expect(saved)
    await staleClient.waitUntilTaskBoardItemsReadIsBlocked()
    for _ in 0..<30 where await signingGate.hasEntered == false {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await signingGate.hasEntered)

    let replacementClient = RecordingHarnessClient()
    replacementClient.taskBoardCapabilitiesValue = TaskBoardCapabilities(
      storage: "database",
      revision: 9,
      instanceID: "replacement-task-board"
    )
    replacementClient.configureTaskBoardItems([taskBoardItem(id: "replacement")])
    try await store.connect(using: replacementClient)
    await signingGate.release()
    await staleClient.releaseTaskBoardItemsRead()
    try await Task.sleep(for: .milliseconds(100))

    #expect(store.taskBoardDatabaseInstanceID == "replacement-task-board")
    #expect(store.globalTaskBoardItems.map(\.id) == ["replacement"])
    #expect(store.currentFailureFeedbackMessage?.contains("stale signing failure") != true)
    await store.prepareForTermination()
  }

  @Test("Repeated ready stops an active task source refresh before credential sync")
  func repeatedReadyStopsActiveTaskSourceRefresh() async throws {
    let client = RecordingHarnessClient()
    client.taskBoardSyncStatusResponse = TaskBoardSyncStatusResponse(
      active: true,
      cancellationRequested: false
    )
    let store = connectedTaskBoardStore(client: client)
    store.adoptDatabaseBackedTaskBoard(client.taskBoardCapabilitiesValue)
    let sourceRefresh = Task { @MainActor in
      await store.syncTaskBoard(request: TaskBoardSyncRequest(direction: .pull))
    }
    #expect(
      await waitUntil {
        client.recordedCalls().contains(.taskBoardSyncStatus)
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
    #expect(await sourceRefresh.value == false)
    let settledStatusCalls = client.recordedCalls().filter { $0 == .taskBoardSyncStatus }.count
    try await Task.sleep(for: .milliseconds(250))

    #expect(client.recordedCalls().contains(.cancelTaskBoardSync))
    let finalStatusCalls = client.recordedCalls().filter { $0 == .taskBoardSyncStatus }.count
    #expect(finalStatusCalls == settledStatusCalls)
    await store.prepareForTermination()
  }

  @Test("Repeated ready also stops a daemon-started source refresh")
  func repeatedReadyStopsDaemonStartedSourceRefresh() async throws {
    let client = RecordingHarnessClient()
    client.taskBoardSyncStatusResponse = TaskBoardSyncStatusResponse(
      active: true,
      cancellationRequested: false
    )
    let store = connectedTaskBoardStore(client: client)
    store.adoptDatabaseBackedTaskBoard(client.taskBoardCapabilitiesValue)
    var hasSeenReady = true

    #expect(
      await store.processGlobalStreamEvent(
        DaemonPushEvent(recordedAt: "2026-08-10T00:00:00Z", sessionId: nil, kind: .ready),
        using: client,
        hasSeenReady: &hasSeenReady
      )
    )

    #expect(client.recordedCalls().contains(.cancelTaskBoardSync))
    #expect(client.recordedCalls().filter { $0 == .taskBoardSyncStatus }.count >= 2)
    #expect(store.taskBoardDatabaseInstanceID == client.taskBoardCapabilitiesValue.instanceID)
    await store.prepareForTermination()
  }

  @Test("Repeated ready revokes an in-flight Task Board read")
  func repeatedReadyRevokesInflightTaskBoardRead() async throws {
    let client = RecordingHarnessClient()
    let store = connectedTaskBoardStore(client: client)
    store.adoptDatabaseBackedTaskBoard(client.taskBoardCapabilitiesValue)
    let gate = RecordingTaskBoardItemsReadGate()
    await gate.blockNextRead()
    let read = Task { @MainActor in
      await store.readTaskBoard { _ in
        await gate.suspendIfConfigured()
        return "stale"
      }
    }

    await gate.waitUntilBlocked()
    _ = try await store.invalidateTaskBoardDatabaseAccess(using: client)
    await gate.release()

    #expect(await read.value == nil)
    await store.prepareForTermination()
  }

  @Test("Connected Task Board clients bypass launch-agent cleanup")
  func connectedTaskBoardClientsBypassLaunchAgentCleanup() async throws {
    let client = RecordingHarnessClient()
    let daemon = RecordingDaemonController(
      legacyCleanupError: DaemonControlError.commandFailed("cleanup must stay off the hot path")
    )
    let credentialPersistence = InMemoryTaskBoardCredentialBundle()
    let keychainBundle = InMemoryTaskBoardKeychainBundle()
    let store = HarnessMonitorStore(
      daemonController: daemon,
      voiceCapture: NativeVoiceCaptureService(),
      taskBoardSettingsWorker: TaskBoardSettingsWorker(
        credentialPersistence: credentialPersistence.persistence,
        keyMaterialPersistence: keychainBundle.persistence
      ),
      taskBoardConnectionHistoryStore: TaskBoardConnectionHistoryStore(defaults: nil)
    )
    store.client = client
    store.taskBoardDatabaseInstanceID = "task-board-live-client"

    _ = try await store.taskBoardHostSnapshot()
    _ = try await store.taskBoardGitSettingsSnapshot()

    #expect(await daemon.recordedLegacyCleanupCallCount() == 0)
  }

  private func taskBoardItem(id: String) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Board item \(id)",
      body: "Body",
      status: .todo,
      priority: .medium,
      tags: [],
      projectId: "project-1",
      agentMode: .interactive,
      kind: .task,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-08-10T08:00:00Z",
      updatedAt: "2026-08-10T08:00:00Z",
      deletedAt: nil
    )
  }

  func connectedTaskBoardStore(client: RecordingHarnessClient) -> HarnessMonitorStore {
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      voiceCapture: NativeVoiceCaptureService(),
      taskBoardSettingsWorker: TaskBoardSettingsWorker(
        credentialPersistence: InMemoryTaskBoardCredentialBundle().persistence,
        keyMaterialPersistence: InMemoryTaskBoardKeychainBundle().persistence
      ),
      taskBoardConnectionHistoryStore: TaskBoardConnectionHistoryStore(defaults: nil)
    )
    store.client = client
    store.connectionState = .online
    return store
  }
}
