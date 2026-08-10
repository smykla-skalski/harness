import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreLifecycleCoreTests {
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
}
