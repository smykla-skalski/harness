import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Workspace window ACP session context")
@MainActor
struct WorkspaceAcpSessionContextRecoveryTests {
  @Test(
    "Store ACP start retries with the restarted managed daemon client after legacy 404 recovery"
  )
  func storeAcpStartUsesRestartedClientAfterLegacy404Recovery() async throws {
    let staleClient = RecordingHarnessClient()
    staleClient.configureAcpStartErrors([
      HarnessMonitorAPIError.server(code: 501, message: "sandbox-disabled - acp.host-bridge")
    ])
    staleClient.configureHostBridgeReconfigureError(
      HarnessMonitorAPIError.server(code: 404, message: "Not Found")
    )

    let recoveredClient = RecordingHarnessClient()
    recoveredClient.configureHostBridgeStatusReport(
      BridgeStatusReport(
        running: true,
        socketPath: "/tmp/bridge.sock",
        pid: 4321,
        startedAt: "2026-04-11T10:00:00Z",
        uptimeSeconds: 15,
        capabilities: [
          "acp": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "unix",
            endpoint: "/tmp/bridge.sock"
          )
        ]
      )
    )

    let daemon = HostBridgeRecoveryDaemonController(
      initialClient: staleClient,
      restartedClient: recoveredClient
    )
    let store = HarnessMonitorStore(daemonController: daemon, daemonOwnership: .managed)
    await store.bootstrap()
    clearRecordedCallsIfNeeded(for: staleClient)
    clearRecordedCallsIfNeeded(for: recoveredClient)
    store.toast.dismissAll()
    store.selectedSessionID = nil
    store.daemonStatus = sandboxedStatus(
      hostBridge: HostBridgeManifest(
        running: true,
        socketPath: "/tmp/bridge.sock",
        capabilities: [:]
      )
    )

    let started = await store.startAcpAgent(
      agentID: "copilot",
      role: .worker,
      capabilities: ["fs.read", "terminal.spawn"],
      name: "Copilot Reviewer",
      prompt: "Review the latest ACP wiring.",
      projectDir: "/tmp/ui-acp",
      persona: "reviewer",
      sessionID: PreviewFixtures.summary.sessionId
    )

    let startedAgentID = try #require(started?.sessionAgentID)
    #expect(startedAgentID.hasPrefix("recording-session-agent-copilot-acp-"))
    #expect(
      staleClient.recordedCalls()
        == [
          expectedAcpStartCall(),
          expectedHostBridgeReconfigureCall(),
        ]
    )
    #expect(
      recoveredClient.recordedCalls()
        == [
          .syncTaskBoardGitHubTokens(globalTokenConfigured: false, repositoryTokenCount: 0),
          .syncTaskBoardTodoistToken(tokenConfigured: false),
          .syncTaskBoardOpenRouterToken(tokenConfigured: false),
          expectedHostBridgeReconfigureCall(),
          expectedAcpStartCall(),
        ]
    )
    #expect(await daemon.recordedOperations() == ["warm-up", "stop", "register", "warm-up"])
    #expect(store.hostBridgeCapabilityState(for: "acp") == .ready)
    #expect(store.currentFailureFeedbackMessage == nil)
  }

  @Test("Store ACP start surfaces ACP disabled errors without bridge recovery")
  func storeAcpStartSurfacesAcpDisabledErrorsWithoutBridgeRecovery() async {
    let client = RecordingHarnessClient()
    let acpDisabledPayload =
      #"{"error":{"code":"ACP_DISABLED","message":"ACP disabled by feature flag","details":[]}}"#
    client.configureAcpStartError(
      HarnessMonitorAPIError.server(
        code: 503,
        message: acpDisabledPayload
      )
    )
    let store = await makeBootstrappedStore(client: client)
    store.toast.dismissAll()
    store.selectedSessionID = nil
    store.hostBridgeCapabilityIssues["acp"] = .unavailable
    store.daemonStatus = sandboxedStatus(
      hostBridge: HostBridgeManifest(
        running: true,
        socketPath: "/tmp/bridge.sock",
        capabilities: [:]
      )
    )

    let started = await store.startAcpAgent(
      agentID: "copilot",
      role: .worker,
      capabilities: ["fs.read", "terminal.spawn"],
      name: "Copilot Reviewer",
      prompt: "Review the latest ACP wiring.",
      projectDir: "/tmp/ui-acp",
      persona: "reviewer",
      sessionID: PreviewFixtures.summary.sessionId
    )

    #expect(started == nil)
    #expect(client.recordedCalls() == [expectedAcpStartCall()])
    #expect(store.hostBridgeCapabilityIssues["acp"] == nil)
    #expect(
      store.currentFailureFeedbackMessage
        == "ACP isn't available in this daemon session. Enable ACP and try again"
    )
  }

  @Test("Store ACP start surfaces session-scope errors without bridge recovery")
  func storeAcpStartSurfacesSessionScopeErrorsWithoutBridgeRecovery() async {
    let client = RecordingHarnessClient()
    let sessionScopeDeniedPayload =
      #"{"error":{"code":"SESSION_SCOPE_DENIED","message":"session scope denied","details":[]}}"#
    client.configureAcpStartError(
      HarnessMonitorAPIError.server(
        code: 403,
        message: sessionScopeDeniedPayload
      )
    )
    let store = await makeBootstrappedStore(client: client)
    store.toast.dismissAll()
    store.selectedSessionID = nil
    store.hostBridgeCapabilityIssues["acp"] = .unavailable
    store.daemonStatus = sandboxedStatus(
      hostBridge: HostBridgeManifest(
        running: true,
        socketPath: "/tmp/bridge.sock",
        capabilities: [:]
      )
    )

    let started = await store.startAcpAgent(
      agentID: "copilot",
      role: .worker,
      capabilities: ["fs.read", "terminal.spawn"],
      name: "Copilot Reviewer",
      prompt: "Review the latest ACP wiring.",
      projectDir: "/tmp/ui-acp",
      persona: "reviewer",
      sessionID: PreviewFixtures.summary.sessionId
    )

    #expect(started == nil)
    #expect(client.recordedCalls() == [expectedAcpStartCall()])
    #expect(store.hostBridgeCapabilityIssues["acp"] == nil)
    #expect(
      store.currentFailureFeedbackMessage
        == "ACP access is limited to the active session. Switch to the matching session and try again"
    )
  }

  private func expectedAcpStartCall() -> RecordingHarnessClient.Call {
    .startAcpAgent(
      sessionID: PreviewFixtures.summary.sessionId,
      agentID: "copilot",
      role: .worker,
      fallbackRole: nil,
      capabilities: ["fs.read", "terminal.spawn"],
      name: "Copilot Reviewer",
      prompt: "Review the latest ACP wiring.",
      projectDir: "/tmp/ui-acp",
      persona: "reviewer",
      model: nil,
      effort: nil,
      allowCustomModel: false,
      recordPermissions: false
    )
  }

  private func expectedHostBridgeReconfigureCall() -> RecordingHarnessClient.Call {
    .reconfigureHostBridge(enable: ["acp"], disable: [], force: false)
  }
}
