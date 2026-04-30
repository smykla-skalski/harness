import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Agents window ACP session context")
@MainActor
struct AgentsWindowAcpSessionContextTests {
  @Test("Create selection retains last session context and reseats selected session when missing")
  func createSelectionRestoresMissingSelectedSession() async {
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [PreviewFixtures.summary],
      detailsByID: [PreviewFixtures.summary.sessionId: PreviewFixtures.detail],
      detail: PreviewFixtures.detail
    )
    let store = await makeBootstrappedStore(client: client)
    let sessionID = PreviewFixtures.summary.sessionId
    store.selectedSessionID = nil

    let view = AgentsWindowView(store: store)
    await view.handleSelectionChange(
      from: .decisions(sessionID: sessionID),
      to: .create
    )

    #expect(view.viewModel.createSessionID == sessionID)
    #expect(store.selectedSessionID == sessionID)
  }

  @Test("ACP start from create uses anchored session instead of no-selection guard")
  func acpStartFromCreateUsesAnchoredSession() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    let view = AgentsWindowView(store: store)
    store.toast.dismissAll()
    store.selectedSessionID = nil
    view.viewModel.selection = .create
    view.viewModel.createSessionID = PreviewFixtures.summary.sessionId
    view.viewModel.selectedLaunchSelection = .acp("copilot")
    view.viewModel.availableAcpAgents = [
      AcpAgentDescriptor(
        id: "copilot",
        displayName: "GitHub Copilot",
        capabilities: ["fs.read", "terminal.spawn"],
        launchCommand: "copilot",
        launchArgs: ["agent", "acp"],
        envPassthrough: [],
        doctorProbe: AcpDoctorProbe(command: "copilot", args: ["--version"])
      )
    ]
    view.viewModel.selectedRole = .leader
    view.viewModel.selectedAcpFallbackRole = .observer
    view.viewModel.selectedPersona = "reviewer"
    view.viewModel.name = "Copilot Reviewer"
    view.viewModel.prompt = "Review the latest ACP wiring."
    view.viewModel.projectDir = "  /tmp/ui-acp  "

    let didHandleAcp = await view.startAcpAgentIfSelected()

    #expect(didHandleAcp)
    #expect(
      client.recordedCalls()
        == [
          .startAcpAgent(
            sessionID: PreviewFixtures.summary.sessionId,
            agentID: "copilot",
            role: .leader,
            fallbackRole: .observer,
            capabilities: ["fs.read", "terminal.spawn"],
            name: "Copilot Reviewer",
            prompt: "Review the latest ACP wiring.",
            projectDir: "/tmp/ui-acp",
            persona: "reviewer",
            recordPermissions: false
          )
        ]
    )
    #expect(store.currentFailureFeedbackMessage == nil)
    #expect(store.selectedSessionActionUnavailableMessage == nil)
    #expect(store.currentFailureFeedbackMessage?.contains("No session is selected") != true)
    #expect(store.selectedSessionID == PreviewFixtures.summary.sessionId)
    #expect(
      store.selectedSession?.agents.contains(where: { $0.agentId == "copilot" }) == true
    )
    #expect(
      store.selectedSession?.agents.first(where: { $0.agentId == "copilot" })?.role == .observer
    )
    #expect(
      view.viewModel.selection
        == .agent(sessionID: PreviewFixtures.summary.sessionId, agentID: "copilot")
    )
  }

  @Test("Store ACP start reseats anchored session detail")
  func storeAcpStartReseatsAnchoredSessionDetail() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.toast.dismissAll()
    store.selectedSessionID = nil

    let started = await store.startAcpAgent(
      agentID: "copilot",
      role: .leader,
      fallbackRole: .observer,
      capabilities: ["fs.read", "terminal.spawn"],
      name: "Copilot Reviewer",
      prompt: "Review the latest ACP wiring.",
      projectDir: "/tmp/ui-acp",
      persona: "reviewer",
      sessionID: PreviewFixtures.summary.sessionId
    )

    #expect(started?.agentId == "copilot")

    await store.refreshSessionDetail(sessionID: PreviewFixtures.summary.sessionId)

    #expect(store.selectedSessionID == PreviewFixtures.summary.sessionId)
    #expect(
      store.selectedSession?.agents.contains(where: { $0.agentId == "copilot" }) == true
    )
    #expect(
      store.selectedSession?.agents.first(where: { $0.agentId == "copilot" })?.role == .observer
    )
  }

  @Test("Store ACP start succeeds with anchored session")
  func storeAcpStartSucceedsWithAnchoredSession() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.toast.dismissAll()
    store.selectedSessionID = nil

    let started = await store.startAcpAgent(
      agentID: "copilot",
      role: .leader,
      fallbackRole: .observer,
      capabilities: ["fs.read", "terminal.spawn"],
      name: "Copilot Reviewer",
      prompt: "Review the latest ACP wiring.",
      projectDir: "/tmp/ui-acp",
      persona: "reviewer",
      sessionID: PreviewFixtures.summary.sessionId
    )

    #expect(started?.agentId == "copilot")
    #expect(store.currentFailureFeedbackMessage == nil)
  }

  @Test("Store ACP start enables ACP host bridge and retries when bridge is already running")
  func storeAcpStartEnablesHostBridgeCapabilityAndRetries() async {
    let client = RecordingHarnessClient()
    client.configureAcpStartErrors([
      HarnessMonitorAPIError.server(code: 501, message: "sandbox-disabled - acp.host-bridge")
    ])
    client.configureHostBridgeStatusReport(
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
    let store = await makeBootstrappedStore(client: client)
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

    #expect(started?.agentId == "copilot")
    #expect(
      client.recordedCalls()
        == [
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
            recordPermissions: false
          ),
          .reconfigureHostBridge(enable: ["acp"], disable: [], force: false),
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
            recordPermissions: false
          ),
        ]
    )
    #expect(store.hostBridgeCapabilityState(for: "acp") == .ready)
    #expect(store.currentFailureFeedbackMessage == nil)
  }
}
