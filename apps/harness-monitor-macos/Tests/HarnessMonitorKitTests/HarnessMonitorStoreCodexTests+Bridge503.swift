import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreCodexTests {
  @Test("Start Codex run sets codexUnavailable when sandboxed daemon returns 503")
  func startCodexRunSetsCodexUnavailableOnSandboxed503() async {
    let client = RecordingHarnessClient()
    client.configureCodexStartError(
      HarnessMonitorAPIError.server(code: 503, message: "codex-unavailable")
    )
    let daemon = RecordingDaemonController(
      client: client,
      statusReport: sandboxedStatus(hostBridge: HostBridgeManifest())
    )
    let store = HarnessMonitorStore(daemonController: daemon)
    await store.bootstrap()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.daemonStatus = sandboxedStatus(hostBridge: HostBridgeManifest())

    let started = await store.startCodexRun(prompt: "Test.", mode: .report)

    #expect(started == false)
    #expect(store.codexUnavailable == true)
    #expect(store.acpBridgeHTTPIncident == nil)
    #expect(store.contentUI.chrome.acpBridgeBanner == nil)
    #expect(store.currentFailureFeedbackMessage?.contains("codex-unavailable") == true)
  }

  @Test(
    "Sandboxed 503 refreshes bridge state and retries Codex start once when the bridge is healthy")
  func startCodexRunRetriesOnceAfterSandboxed503WhenBridgeRefreshesHealthy() async {
    let client = RecordingHarnessClient()
    client.configureCodexStartErrors([
      HarnessMonitorAPIError.server(code: 503, message: "codex-unavailable")
    ])
    let daemon = RecordingDaemonController(
      client: client,
      statusReport: sandboxedStatus(
        hostBridge: HostBridgeManifest(
          running: true,
          socketPath: "/tmp/bridge.sock",
          capabilities: [
            "codex": HostBridgeCapabilityManifest(
              healthy: true,
              transport: "websocket",
              endpoint: "ws://127.0.0.1:4500"
            )
          ]
        )
      )
    )
    let store = HarnessMonitorStore(daemonController: daemon)
    await store.bootstrap()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.daemonStatus = sandboxedStatus(hostBridge: HostBridgeManifest())

    let started = await store.startCodexRun(prompt: "Test.", mode: .report)

    #expect(started)
    #expect(
      client.recordedCalls()
        == [
          .startCodexRun(
            sessionID: PreviewFixtures.summary.sessionId,
            prompt: "Test.",
            mode: .report,
            actor: "leader-claude",
            resumeThreadID: nil
          ),
          .startCodexRun(
            sessionID: PreviewFixtures.summary.sessionId,
            prompt: "Test.",
            mode: .report,
            actor: "leader-claude",
            resumeThreadID: nil
          ),
        ]
    )
    #expect(store.codexUnavailable == false)
    #expect(store.acpBridgeHTTPIncident == nil)
    #expect(store.contentUI.chrome.acpBridgeBanner == nil)
    #expect(store.daemonStatus?.manifest?.hostBridge.running == true)
    #expect(store.daemonStatus?.manifest?.hostBridge.capabilities["codex"]?.healthy == true)
    #expect(store.currentSuccessFeedbackMessage == "Codex run started")
  }

  @Test("Sandboxed 503 keeps running bridge unavailable when the retry still fails")
  func startCodexRunKeepsRunningBridgeUnavailableWhenRetryStillFails() async {
    let client = RecordingHarnessClient()
    client.configureCodexStartErrors([
      HarnessMonitorAPIError.server(code: 503, message: "codex-unavailable"),
      HarnessMonitorAPIError.server(code: 503, message: "codex-unavailable"),
    ])
    let daemon = RecordingDaemonController(
      client: client,
      statusReport: sandboxedStatus(
        hostBridge: HostBridgeManifest(
          running: true,
          socketPath: "/tmp/bridge.sock",
          capabilities: [
            "codex": HostBridgeCapabilityManifest(
              healthy: true,
              transport: "websocket",
              endpoint: "ws://127.0.0.1:4500"
            )
          ]
        )
      )
    )
    let store = HarnessMonitorStore(daemonController: daemon)
    await store.bootstrap()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.daemonStatus = sandboxedStatus(hostBridge: HostBridgeManifest())

    let started = await store.startCodexRun(prompt: "Test.", mode: .report)

    #expect(started == false)
    #expect(
      client.recordedCalls()
        == [
          .startCodexRun(
            sessionID: PreviewFixtures.summary.sessionId,
            prompt: "Test.",
            mode: .report,
            actor: "leader-claude",
            resumeThreadID: nil
          ),
          .startCodexRun(
            sessionID: PreviewFixtures.summary.sessionId,
            prompt: "Test.",
            mode: .report,
            actor: "leader-claude",
            resumeThreadID: nil
          ),
        ]
    )
    #expect(store.codexUnavailable == true)
    #expect(store.acpBridgeHTTPIncident == nil)
    #expect(store.contentUI.chrome.acpBridgeBanner == nil)
    #expect(store.hostBridgeCapabilityState(for: "codex") == .unavailable)
    #expect(
      store.hostBridgeStartCommand(for: "codex") == "harness bridge reconfigure --enable codex")
    #expect(store.currentFailureFeedbackMessage?.contains("codex-unavailable") == true)
  }

  @Test("Sandboxed 503 retry still counts when the retry fails with 501")
  func startCodexRunCountsRetryWhenRetryFailsWith501() async {
    let client = RecordingHarnessClient()
    client.configureCodexStartErrors([
      HarnessMonitorAPIError.server(code: 503, message: "codex-unavailable"),
      HarnessMonitorAPIError.server(code: 501, message: "codex-excluded"),
    ])
    let daemon = RecordingDaemonController(
      client: client,
      statusReport: sandboxedStatus(
        hostBridge: HostBridgeManifest(
          running: true,
          socketPath: "/tmp/bridge.sock",
          capabilities: [
            "codex": HostBridgeCapabilityManifest(
              healthy: true,
              transport: "websocket",
              endpoint: "ws://127.0.0.1:4500"
            )
          ]
        )
      )
    )
    let store = HarnessMonitorStore(daemonController: daemon)
    await store.bootstrap()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.daemonStatus = sandboxedStatus(hostBridge: HostBridgeManifest())

    let started = await store.startCodexRun(prompt: "Test.", mode: .report)

    #expect(started == false)
    #expect(
      client.recordedCalls()
        == [
          .startCodexRun(
            sessionID: PreviewFixtures.summary.sessionId,
            prompt: "Test.",
            mode: .report,
            actor: "leader-claude",
            resumeThreadID: nil
          ),
          .startCodexRun(
            sessionID: PreviewFixtures.summary.sessionId,
            prompt: "Test.",
            mode: .report,
            actor: "leader-claude",
            resumeThreadID: nil
          ),
        ]
    )
    #expect(store.codexUnavailable == true)
    #expect(store.acpBridgeHTTPIncident == nil)
    #expect(store.contentUI.chrome.acpBridgeBanner == nil)
    #expect(store.currentFailureFeedbackMessage?.contains("codex-excluded") == true)
  }

  @Test("Start Codex run keeps host bridge ready when daemon is not sandboxed")
  func startCodexRunDoesNotSetCodexUnavailableOnUnsandboxed503() async {
    let client = RecordingHarnessClient()
    client.configureCodexStartError(
      HarnessMonitorAPIError.server(code: 503, message: "codex-unavailable")
    )
    let store = await selectedStore(client: client)

    let started = await store.startCodexRun(prompt: "Test.", mode: .report)

    #expect(started == false)
    #expect(store.codexUnavailable == false)
    #expect(store.acpBridgeHTTPIncident == nil)
    #expect(store.contentUI.chrome.acpBridgeBanner == nil)
    #expect(store.currentFailureFeedbackMessage?.contains("codex-unavailable") == true)
  }

  @Test("Successful Codex run clears codexUnavailable flag")
  func successfulCodexRunClearsCodexUnavailable() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)
    store.hostBridgeCapabilityIssues["codex"] = .unavailable

    let started = await store.startCodexRun(prompt: "Patch it.", mode: .report)

    #expect(started == true)
    #expect(store.codexUnavailable == false)
  }

  @Test("Non-503 error does not set codexUnavailable")
  func non503ErrorDoesNotSetCodexUnavailable() async {
    let client = RecordingHarnessClient()
    client.configureCodexStartError(
      HarnessMonitorAPIError.server(code: 400, message: "bad request")
    )
    let store = await selectedStore(client: client)

    let started = await store.startCodexRun(prompt: "Test.", mode: .report)

    #expect(started == false)
    #expect(store.codexUnavailable == false)
  }
}
