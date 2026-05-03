import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreTests {
  @Test("Refreshing diagnostics loads live daemon diagnostics")
  func refreshDiagnosticsLoadsLiveDaemonDiagnostics() async {
    let store = await makeBootstrappedStore()

    store.diagnostics = nil

    await store.refreshDiagnostics()

    #expect(store.diagnostics?.workspace.databaseSizeBytes == 1_740_800)
    #expect(store.diagnostics?.recentEvents.count == 1)
  }

  @Test("Bootstrap failure sets the offline state and error")
  func bootstrapFailureSetsOfflineStateAndError() async {
    let daemon = FailingDaemonController(
      bootstrapError: DaemonControlError.harnessBinaryNotFound
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()

    #expect(
      store.connectionState
        == .offline(DaemonControlError.harnessBinaryNotFound.localizedDescription)
    )
    #expect(store.currentFailureFeedbackMessage != nil)
    #expect(store.health == nil)
  }

  @Test("Create task failure sets the last error")
  func createTaskFailureSetsLastError() async {
    let client = FailingHarnessClient()
    let daemon = RecordingDaemonController(client: client)
    let store = HarnessMonitorStore(daemonController: daemon)
    await store.bootstrap()
    await store.selectSession("sess-1")

    await store.createTask(title: "broken", context: nil, severity: .high)

    #expect(store.currentFailureFeedbackMessage != nil)
    #expect(store.isBusy == false)
  }

  @Test("Refresh with no client triggers bootstrap")
  func refreshWithNoClientTriggersBootstrap() async {
    let daemon = FailingDaemonController(
      bootstrapError: DaemonControlError.daemonDidNotStart
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.refresh()

    #expect(store.currentFailureFeedbackMessage != nil)
  }

  @Test("ACP bridge doctor clears the outage when inspect succeeds")
  func acpBridgeDoctorClearsOutageWhenInspectSucceeds() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.selectedSessionID = PreviewFixtures.summary.sessionId
    let initialInspectCallCount = client.acpInspectCallCount(
      for: PreviewFixtures.summary.sessionId
    )
    store.daemonStatus = sandboxedStatus(
      hostBridge: HostBridgeManifest(
        running: true,
        socketPath: "/tmp/harness-bridge.sock",
        capabilities: [
          "acp": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "http",
            endpoint: "http://127.0.0.1:4546"
          )
        ]
      )
    )
    store.markHostBridgeIssue(for: "acp", statusCode: 503)

    #expect(store.contentUI.chrome.acpBridgeBanner != nil)

    await store.runAcpBridgeDoctor()

    #expect(
      client.acpInspectCallCount(for: PreviewFixtures.summary.sessionId)
        == initialInspectCallCount + 1
    )
    #expect(store.acpBridgeHTTPIncident == nil)
    #expect(store.contentUI.chrome.acpBridgeBanner == nil)
    #expect(store.currentSuccessFeedbackMessage == "ACP bridge recovered")
    #expect(store.currentFailureFeedbackMessage == nil)
  }

  @Test("ACP bridge doctor surfaces the ACP inspect failure")
  func acpBridgeDoctorSurfacesInspectFailure() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.selectedSessionID = PreviewFixtures.summary.sessionId
    let initialInspectCallCount = client.acpInspectCallCount(
      for: PreviewFixtures.summary.sessionId
    )
    client.lock.withLock {
      client.acpInspectResponsesBySessionID[PreviewFixtures.summary.sessionId] = [
        AcpAgentInspectResponse(
          agents: [],
          available: false,
          issueMessage: "ACP runtime probe unavailable."
        )
      ]
    }
    store.daemonStatus = sandboxedStatus(
      hostBridge: HostBridgeManifest(
        running: true,
        socketPath: "/tmp/harness-bridge.sock",
        capabilities: [
          "acp": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "http",
            endpoint: "http://127.0.0.1:4546"
          )
        ]
      )
    )
    store.markHostBridgeIssue(for: "acp", statusCode: 503)

    #expect(store.contentUI.chrome.acpBridgeBanner != nil)

    await store.runAcpBridgeDoctor()

    #expect(
      client.acpInspectCallCount(for: PreviewFixtures.summary.sessionId)
        == initialInspectCallCount + 1
    )
    #expect(store.contentUI.chrome.acpBridgeBanner != nil)
    #expect(store.currentSuccessFeedbackMessage == nil)
    #expect(store.currentFailureFeedbackMessage == "ACP runtime probe unavailable.")
  }
}
