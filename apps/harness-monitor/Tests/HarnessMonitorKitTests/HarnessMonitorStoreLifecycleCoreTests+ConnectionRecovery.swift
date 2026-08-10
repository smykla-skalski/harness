import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreLifecycleCoreTests {
  @Test("A connection is not published before its initial refresh commits")
  func connectionIsNotPublishedBeforeInitialRefreshCommits() async {
    let client = RecordingHarnessClient()
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    await client.blockNextTaskBoardItemsRead()
    let connection = Task { @MainActor in
      try? await store.connect(using: client)
    }

    await client.waitUntilTaskBoardItemsReadIsBlocked()
    #expect(store.client == nil)
    store.invalidateConnectionAttempts()
    await client.releaseTaskBoardItemsRead()
    await connection.value

    #expect(store.client == nil)
    #expect(client.shutdownCallCount() == 1)
    await store.prepareForTermination()
  }

  @Test("A stale connection attempt closes only its distinct candidate")
  func staleConnectionAttemptClosesOnlyDistinctCandidate() async throws {
    let activeClient = RecordingHarnessClient()
    let staleClient = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: activeClient)
    let staleFence = try store.currentConnectionAttemptFence()
    store.invalidateConnectionAttempts()

    await store.settleAbandonedConnectionAttempt(
      using: staleClient,
      connectionFence: staleFence
    )
    await store.settleAbandonedConnectionAttempt(
      using: activeClient,
      connectionFence: staleFence
    )

    #expect(staleClient.shutdownCallCount() == 1)
    #expect(activeClient.shutdownCallCount() == 0)
    #expect(store.client === activeClient)
    #expect(store.connectionState == .online)
    await store.prepareForTermination()
  }

  @Test("External bootstrap keeps retrying after consecutive transient failures")
  func externalBootstrapKeepsRetryingAfterConsecutiveFailures() async {
    let failedClient = RecordingHarnessClient()
    failedClient.configureTaskBoardGitHubTokensSyncError(
      HarnessMonitorAPIError.server(code: 503, message: "first credential sync failure")
    )
    let retryClient = RecordingHarnessClient()
    retryClient.configureTaskBoardGitHubTokensSyncError(
      HarnessMonitorAPIError.server(code: 503, message: "second credential sync failure")
    )
    let recoveredClient = RecordingHarnessClient()
    let daemon = RecordingDaemonController(
      client: failedClient,
      bootstrapOutcomes: [.success(retryClient), .success(recoveredClient)]
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      daemonOwnership: .external
    )
    store.connectionRecoveryRetryDelays = [.milliseconds(1)]

    await store.bootstrapIfNeeded()

    #expect(
      await waitUntil(timeout: .seconds(2)) {
        store.connectionState == .online
          && (store.client as? RecordingHarnessClient) === recoveredClient
      }
    )
    #expect(await daemon.recordedBootstrapCallCount() == 2)
    await store.prepareForTermination()
  }

  @Test("App suspension cancels an in-flight external retry")
  func appSuspensionCancelsInFlightExternalRetry() async {
    let failedClient = RecordingHarnessClient()
    failedClient.configureTaskBoardGitHubTokensSyncError(
      HarnessMonitorAPIError.server(code: 503, message: "credential sync failure")
    )
    let retryCapabilitiesGate = LegacyContainmentCapabilitiesGate()
    let retryClient = RecordingHarnessClient()
    retryClient.taskBoardCapabilitiesHandler = { await retryCapabilitiesGate.wait() }
    let daemon = RecordingDaemonController(
      client: failedClient,
      bootstrapOutcomes: [.success(retryClient)]
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      daemonOwnership: .external
    )
    let bootstrap = Task { @MainActor in await store.bootstrapIfNeeded() }

    #expect(await waitUntil { await retryCapabilitiesGate.hasEntered })
    await store.performAppInactivitySuspend()
    await retryCapabilitiesGate.release()
    await bootstrap.value

    #expect(store.connectionState == .idle)
    #expect(store.client == nil)
    #expect(store.manifestWatcher == nil)
    #expect(store.connectionRecoveryTask == nil)
    await store.prepareForTermination()
  }

  @Test("Managed bootstrap keeps retrying after its foreground retry fails")
  func managedBootstrapKeepsRetryingAfterForegroundRetryFails() async {
    let recoveredClient = RecordingHarnessClient()
    let daemon = RecordingDaemonController(
      client: recoveredClient,
      bootstrapOutcomes: [
        .failure(HarnessMonitorAPIError.server(code: 503, message: "foreground retry failed"))
      ]
    )
    let store = HarnessMonitorStore(daemonController: daemon)
    store.connectionRecoveryRetryDelays = [.milliseconds(1)]

    #expect(
      await store.recoverManagedBootstrapFailure(
        from: HarnessMonitorAPIError.server(code: 503, message: "managed connect failed")
      ) == false
    )
    #expect(
      await waitUntil(timeout: .seconds(2)) {
        store.connectionState == .online
          && (store.client as? RecordingHarnessClient) === recoveredClient
      }
    )
    #expect(await daemon.recordedBootstrapCallCount() == 1)
    #expect(await daemon.recordedWarmUpCallCount() == 1)
    await store.prepareForTermination()
  }

  @Test("Managed retry honors app suspension before publishing failure")
  func managedRetryHonorsAppSuspension() async {
    let capabilitiesGate = LegacyContainmentCapabilitiesGate()
    let retryClient = RecordingHarnessClient()
    retryClient.taskBoardCapabilitiesHandler = { await capabilitiesGate.wait() }
    let daemon = RecordingDaemonController(bootstrapOutcomes: [.success(retryClient)])
    let store = HarnessMonitorStore(daemonController: daemon)
    store.isBootstrapping = true
    let recovery = Task { @MainActor in
      await store.recoverManagedBootstrapFailure(
        from: HarnessMonitorAPIError.server(code: 503, message: "managed connect failed")
      )
    }

    #expect(await waitUntil { await capabilitiesGate.hasEntered })
    await store.performAppInactivitySuspend()
    await capabilitiesGate.release()

    #expect(await recovery.value)
    #expect(store.connectionState == .idle)
    #expect(store.currentFailureFeedbackMessage == nil)
    #expect(store.connectionRecoveryTask == nil)
    store.isBootstrapping = false
    await store.prepareForTermination()
  }
}
