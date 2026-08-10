import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreHostBridgeTests {
  @Test("Managed host bridge recovery publishes connection failure as offline")
  func managedHostBridgeRecoveryConnectFailureGoesOffline() async {
    let staleClient = RecordingHarnessClient()
    staleClient.configureHostBridgeReconfigureError(
      HarnessMonitorAPIError.server(code: 404, message: "Not Found")
    )
    let restartedClient = RecordingHarnessClient()
    let daemon = HostBridgeRecoveryDaemonController(
      initialClient: staleClient,
      restartedClient: restartedClient
    )
    let store = HarnessMonitorStore(daemonController: daemon, daemonOwnership: .managed)
    await store.bootstrap()
    let syncError = HarnessMonitorAPIError.server(
      code: 503,
      message: "credential sync unavailable"
    )
    staleClient.configureTaskBoardGitHubTokensSyncError(syncError)
    restartedClient.configureTaskBoardGitHubTokensSyncError(syncError)

    let result = await store.setHostBridgeCapability("codex", enabled: true)

    #expect(result == .failed)
    #expect(store.client == nil)
    guard case .offline(let reason) = store.connectionState else {
      Issue.record("Expected host bridge recovery failure to leave the store offline")
      return
    }
    #expect(reason.contains("credential synchronization did not complete"))
    await store.prepareForTermination()
  }

  @Test("Managed host bridge recovery uses a concurrently adopted client")
  func managedHostBridgeRecoveryUsesConcurrentlyAdoptedClient() async throws {
    let sourceGate = LegacyContainmentVoidGate()
    let staleClient = RecordingHarnessClient()
    staleClient.configureHostBridgeReconfigureError(
      HarnessMonitorAPIError.server(code: 404, message: "Not Found")
    )
    let restartedClient = RecordingHarnessClient()
    restartedClient.taskBoardGitRuntimeConfigHandler = {
      await sourceGate.wait()
      return restartedClient.sampleTaskBoardGitRuntimeConfig()
    }
    let adoptedClient = RecordingHarnessClient()
    adoptedClient.configureHostBridgeStatusReport(
      BridgeStatusReport(
        running: true,
        socketPath: "/tmp/bridge.sock",
        pid: 4_321,
        startedAt: "2026-04-11T10:00:00Z",
        uptimeSeconds: 15,
        capabilities: [
          "codex": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "websocket",
            endpoint: "ws://127.0.0.1:4500"
          )
        ]
      )
    )
    let daemon = HostBridgeRecoveryDaemonController(
      initialClient: staleClient,
      restartedClient: restartedClient
    )
    let store = HarnessMonitorStore(daemonController: daemon, daemonOwnership: .managed)
    await store.bootstrap()
    let mutation = Task { @MainActor in
      await store.setHostBridgeCapability("codex", enabled: true)
    }

    for _ in 0..<30 where await sourceGate.hasEntered == false {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await sourceGate.hasEntered)
    try await store.connect(using: adoptedClient)
    await sourceGate.release()

    #expect(await mutation.value == .success)
    #expect(
      adoptedClient.recordedCalls().last
        == .reconfigureHostBridge(enable: ["codex"], disable: [], force: false)
    )
    #expect(
      restartedClient.recordedCalls().contains {
        if case .reconfigureHostBridge = $0 { return true }
        return false
      } == false
    )
    #expect(store.currentFailureFeedbackMessage == nil)
    await store.prepareForTermination()
  }
}
