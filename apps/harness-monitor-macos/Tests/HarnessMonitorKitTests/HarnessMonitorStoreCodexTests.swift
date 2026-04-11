import Darwin
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor Codex flow")
struct HarnessMonitorStoreCodexTests {
  @Test("Start Codex run sends request and selects returned run")
  func startCodexRunSendsRequestAndSelectsReturnedRun() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

    let started = await store.startCodexRun(
      prompt: "Investigate the failing suite.",
      mode: .workspaceWrite,
      actor: "leader-claude"
    )

    #expect(started)
    #expect(
      client.recordedCalls()
        == [
          .startCodexRun(
            sessionID: PreviewFixtures.summary.sessionId,
            prompt: "Investigate the failing suite.",
            mode: .workspaceWrite,
            actor: "leader-claude",
            resumeThreadID: nil
          )
        ]
    )
    #expect(store.selectedCodexRun?.prompt == "Investigate the failing suite.")
    #expect(store.selectedCodexRun?.mode == .workspaceWrite)
    #expect(store.lastAction == "Codex run started")
  }

  @Test("Codex approval resolution clears pending approval")
  func codexApprovalResolutionClearsPendingApproval() async {
    let client = RecordingHarnessClient()
    let approval = client.codexApprovalFixture()
    let run = client.codexRunFixture(
      mode: .approval,
      status: .waitingApproval,
      pendingApprovals: [approval]
    )
    client.configureCodexRuns([run], for: PreviewFixtures.summary.sessionId)
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

    let resolved = await store.resolveCodexApproval(
      runID: run.runId,
      approvalID: approval.approvalId,
      decision: .accept
    )

    #expect(resolved)
    #expect(
      client.recordedCalls()
        == [
          .resolveCodexApproval(
            runID: run.runId,
            approvalID: approval.approvalId,
            decision: .accept
          )
        ]
    )
    #expect(store.selectedCodexRun?.pendingApprovals.isEmpty == true)
    #expect(store.selectedCodexRun?.status == .running)
  }

  @Test("Codex stream update refreshes selected run")
  func codexStreamUpdateRefreshesSelectedRun() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)
    let run = client.codexRunFixture(status: .completed, finalMessage: "Done.")

    store.applySessionPushEvent(
      DaemonPushEvent(
        recordedAt: "2026-04-09T10:02:00Z",
        sessionId: PreviewFixtures.summary.sessionId,
        kind: .codexRunUpdated(run)
      )
    )

    #expect(store.selectedCodexRun?.runId == run.runId)
    #expect(store.selectedCodexRun?.status == .completed)
    #expect(store.selectedCodexRun?.finalMessage == "Done.")
  }

  @Test("Codex actions stay read-only while daemon is offline")
  func codexActionsStayReadOnlyWhileDaemonIsOffline() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)
    store.connectionState = .offline("daemon down")

    let started = await store.startCodexRun(prompt: "Patch it.", mode: .workspaceWrite)

    #expect(started == false)
    #expect(client.recordedCalls().isEmpty)
    #expect(store.lastError?.contains("read-only mode") == true)
  }

  @Test("Start Codex run sets codexUnavailable when daemon returns 503")
  func startCodexRunSetsCodexUnavailableOn503() async {
    let client = RecordingHarnessClient()
    client.configureCodexStartError(
      HarnessMonitorAPIError.server(code: 503, message: "codex-unavailable")
    )
    let store = await selectedStore(client: client)

    let started = await store.startCodexRun(prompt: "Test.", mode: .report)

    #expect(started == false)
    #expect(store.codexUnavailable == true)
    #expect(store.lastError?.contains("codex-unavailable") == true)
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

  private func selectedStore(client: RecordingHarnessClient) async -> HarnessMonitorStore {
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)
    return store
  }
}

@MainActor
@Suite("Harness Monitor agent TUI flow")
struct HarnessMonitorStoreAgentTuiTests {
  @Test("Start agent TUI sends request and selects returned snapshot")
  func startAgentTuiSendsRequestAndSelectsReturnedSnapshot() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)

    let started = await store.startAgentTui(
      runtime: .copilot,
      name: "Copilot TUI",
      prompt: "Investigate the latest failure.",
      rows: 30,
      cols: 110
    )

    #expect(started)
    #expect(
      client.recordedCalls()
        == [
          .startAgentTui(
            sessionID: PreviewFixtures.summary.sessionId,
            runtime: "copilot",
            name: "Copilot TUI",
            prompt: "Investigate the latest failure.",
            rows: 30,
            cols: 110
          )
        ]
    )
    #expect(store.selectedAgentTui?.runtime == "copilot")
    #expect(store.selectedAgentTui?.size == AgentTuiSize(rows: 30, cols: 110))
    #expect(store.lastAction == "Agent TUI started")
  }

  @Test("Agent TUI input updates the selected screen snapshot")
  func agentTuiInputUpdatesSelectedScreenSnapshot() async {
    let client = RecordingHarnessClient()
    let tui = client.agentTuiFixture()
    client.configureAgentTuis([tui], for: PreviewFixtures.summary.sessionId)
    let store = await selectedStore(client: client)

    let sent = await store.sendAgentTuiInput(tuiID: tui.tuiId, input: .text("status"))

    #expect(sent)
    #expect(client.recordedCalls() == [.sendAgentTuiInput(tuiID: tui.tuiId, input: .text("status"))])
    #expect(store.selectedAgentTui?.screen.text.contains("status") == true)
  }

  @Test("Agent TUI stream update refreshes selected TUI")
  func agentTuiStreamUpdateRefreshesSelectedTui() async {
    let client = RecordingHarnessClient()
    let running = client.agentTuiFixture(screenText: "copilot> ready")
    client.configureAgentTuis([running], for: PreviewFixtures.summary.sessionId)
    let store = await selectedStore(client: client)
    let updated = client.agentTuiFixture(
      tuiID: running.tuiId,
      status: .stopped,
      screenText: "copilot> done"
    )

    store.applySessionPushEvent(
      DaemonPushEvent(
        recordedAt: "2026-04-10T09:02:00Z",
        sessionId: PreviewFixtures.summary.sessionId,
        kind: .agentTuiUpdated(updated)
      )
    )

    #expect(store.selectedAgentTui?.tuiId == running.tuiId)
    #expect(store.selectedAgentTui?.status == .stopped)
    #expect(store.selectedAgentTui?.screen.text == "copilot> done")
  }

  @Test("Agent TUI actions stay read-only while daemon is offline")
  func agentTuiActionsStayReadOnlyWhileDaemonIsOffline() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)
    store.connectionState = .offline("daemon down")

    let started = await store.startAgentTui(
      runtime: .copilot,
      name: nil,
      prompt: "Patch it.",
      rows: 24,
      cols: 100
    )

    #expect(started == false)
    #expect(client.recordedCalls().isEmpty)
    #expect(store.lastError?.contains("read-only mode") == true)
  }

  @Test("Start agent TUI sets unavailable flag when daemon returns 501")
  func startAgentTuiSetsUnavailableFlagOn501() async {
    let client = RecordingHarnessClient()
    client.configureAgentTuiStartError(
      HarnessMonitorAPIError.server(code: 501, message: "agent-tui bridge unavailable")
    )
    let store = await selectedStore(client: client)

    let started = await store.startAgentTui(
      runtime: .copilot,
      name: nil,
      prompt: "Test.",
      rows: 24,
      cols: 100
    )

    #expect(started == false)
    #expect(store.agentTuiUnavailable == true)
    #expect(store.lastError?.contains("bridge unavailable") == true)
  }

  @Test("Successful agent TUI start clears unavailable flag")
  func successfulAgentTuiStartClearsUnavailableFlag() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)
    store.hostBridgeCapabilityIssues["agent-tui"] = .unavailable

    let started = await store.startAgentTui(
      runtime: .copilot,
      name: nil,
      prompt: "Patch it.",
      rows: 24,
      cols: 100
    )

    #expect(started == true)
    #expect(store.agentTuiUnavailable == false)
  }

  private func selectedStore(client: RecordingHarnessClient) async -> HarnessMonitorStore {
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)
    return store
  }
}

@MainActor
@Suite("Harness Monitor host bridge state")
struct HarnessMonitorStoreHostBridgeTests {
  @Test("Host bridge capability state reports excluded when running bridge omits capability")
  func hostBridgeCapabilityStateReportsExcludedCapability() async {
    let store = await makeBootstrappedStore()
    store.daemonStatus = sandboxedStatus(
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

    #expect(store.hostBridgeCapabilityState(for: "agent-tui") == .excluded)
    #expect(store.agentTuiUnavailable == true)
  }

  @Test("Host bridge capability state ignores stale excluded issue when the bridge stops")
  func hostBridgeCapabilityStateIgnoresStaleExcludedIssueWhenBridgeStops() async {
    let store = await makeBootstrappedStore()
    store.daemonStatus = sandboxedStatus(hostBridge: HostBridgeManifest())
    store.hostBridgeCapabilityIssues["agent-tui"] = .excluded

    #expect(store.hostBridgeCapabilityState(for: "agent-tui") == .unavailable)
    #expect(store.hostBridgeStartCommand(for: "agent-tui") == "harness bridge start")
  }

  @Test("Host bridge start command narrows to missing capability when running bridge excludes it")
  func hostBridgeStartCommandNarrowsToMissingCapability() async {
    let store = await makeBootstrappedStore()
    store.daemonStatus = sandboxedStatus(
      hostBridge: HostBridgeManifest(
        running: true,
        socketPath: "/tmp/bridge.sock",
        capabilities: [
          "agent-tui": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "unix",
            endpoint: "/tmp/bridge.sock"
          )
        ]
      )
    )

    #expect(store.hostBridgeStartCommand(for: "codex") == "harness bridge reconfigure --enable codex")
  }

  @Test("Host bridge start command falls back to bridge start when the bridge is absent")
  func hostBridgeStartCommandFallsBackToStartWhenBridgeIsAbsent() async {
    let store = await makeBootstrappedStore()

    #expect(store.hostBridgeStartCommand(for: "codex") == "harness bridge start")
    #expect(store.hostBridgeStartCommand(for: "agent-tui") == "harness bridge start")
  }

  @Test("Preview store inherits forced bridge issues from process environment")
  func previewStoreInheritsForcedBridgeIssuesFromEnvironment() async {
    setenv("HARNESS_MONITOR_FORCE_BRIDGE_ISSUES", "agent-tui,codex", 1)
    defer { unsetenv("HARNESS_MONITOR_FORCE_BRIDGE_ISSUES") }
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded)
    #expect(store.hostBridgeCapabilityIssues["agent-tui"] == .excluded)
    #expect(store.hostBridgeCapabilityIssues["codex"] == .excluded)
  }

  @Test("HARNESS_MONITOR_FORCE_BRIDGE_ISSUES seeds excluded state for listed capabilities")
  func forceBridgeIssuesEnvSeedsExcludedState() {
    let single = HarnessMonitorStore.parseForcedBridgeIssues(
      from: ["HARNESS_MONITOR_FORCE_BRIDGE_ISSUES": "agent-tui"]
    )
    #expect(single == ["agent-tui": .excluded])

    let multiple = HarnessMonitorStore.parseForcedBridgeIssues(
      from: ["HARNESS_MONITOR_FORCE_BRIDGE_ISSUES": "agent-tui,codex"]
    )
    #expect(multiple == ["agent-tui": .excluded, "codex": .excluded])

    let withWhitespace = HarnessMonitorStore.parseForcedBridgeIssues(
      from: ["HARNESS_MONITOR_FORCE_BRIDGE_ISSUES": " agent-tui , codex "]
    )
    #expect(withWhitespace == ["agent-tui": .excluded, "codex": .excluded])

    let emptyValue = HarnessMonitorStore.parseForcedBridgeIssues(
      from: ["HARNESS_MONITOR_FORCE_BRIDGE_ISSUES": ""]
    )
    #expect(emptyValue.isEmpty)

    let missing = HarnessMonitorStore.parseForcedBridgeIssues(from: [:])
    #expect(missing.isEmpty)
  }

  @Test("501 bridge issue marks excluded only when running bridge omits capability")
  func markHostBridgeIssueUsesExcludedForMissingCapability() async {
    let store = await makeBootstrappedStore()
    store.daemonStatus = sandboxedStatus(
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

    store.markHostBridgeIssue(for: "agent-tui", statusCode: 501)

    #expect(store.hostBridgeCapabilityState(for: "agent-tui") == .excluded)
    #expect(store.hostBridgeStartCommand(for: "agent-tui") == "harness bridge reconfigure --enable agent-tui")
  }

  @Test("Host bridge enable updates manifest and clears excluded issue")
  func setHostBridgeCapabilityEnableUpdatesManifest() async {
    let client = RecordingHarnessClient()
    client.configureHostBridgeStatusReport(
      BridgeStatusReport(
        running: true,
        socketPath: "/tmp/bridge.sock",
        pid: 4321,
        startedAt: "2026-04-11T10:00:00Z",
        uptimeSeconds: 15,
        capabilities: [
          "codex": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "websocket",
            endpoint: "ws://127.0.0.1:4500"
          ),
          "agent-tui": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "unix",
            endpoint: "/tmp/bridge.sock"
          ),
        ]
      )
    )
    let store = await makeBootstrappedStore(client: client)
    store.daemonStatus = sandboxedStatus(
      hostBridge: HostBridgeManifest(
        running: true,
        socketPath: "/tmp/bridge.sock",
        capabilities: [
          "agent-tui": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "unix",
            endpoint: "/tmp/bridge.sock"
          )
        ]
      )
    )
    store.hostBridgeCapabilityIssues["codex"] = .excluded

    let result = await store.setHostBridgeCapability("codex", enabled: true)

    #expect(result == .success)
    #expect(
      client.recordedCalls()
        == [.reconfigureHostBridge(enable: ["codex"], disable: [], force: false)]
    )
    #expect(store.hostBridgeCapabilityIssues["codex"] == nil)
    #expect(store.hostBridgeCapabilityState(for: "codex") == .ready)
    #expect(store.daemonStatus?.manifest?.hostBridge.capabilities["codex"]?.endpoint == "ws://127.0.0.1:4500")
    #expect(store.lastAction == "Enabled Codex host bridge")
  }

  @Test("Managed host bridge reconfigure recovers from legacy daemon 404 by restarting once")
  func setHostBridgeCapabilityManaged404RecoveryRestartsDaemon() async {
    let staleClient = RecordingHarnessClient()
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
          "agent-tui": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "unix",
            endpoint: "/tmp/bridge.sock"
          ),
          "codex": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "websocket",
            endpoint: "ws://127.0.0.1:4500"
          ),
        ]
      )
    )
    let daemon = HostBridgeRecoveryDaemonController(
      initialClient: staleClient,
      restartedClient: recoveredClient
    )
    let store = HarnessMonitorStore(daemonController: daemon, daemonOwnership: .managed)
    await store.bootstrap()
    store.daemonStatus = sandboxedStatus(
      hostBridge: HostBridgeManifest(
        running: true,
        socketPath: "/tmp/bridge.sock",
        capabilities: [
          "agent-tui": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "unix",
            endpoint: "/tmp/bridge.sock"
          )
        ]
      )
    )
    store.hostBridgeCapabilityIssues["codex"] = .excluded

    let result = await store.setHostBridgeCapability("codex", enabled: true)

    #expect(result == .success)
    #expect(
      recoveredClient.recordedCalls()
        == [.reconfigureHostBridge(enable: ["codex"], disable: [], force: false)]
    )
    #expect(await daemon.recordedOperations() == ["warm-up", "stop", "register", "warm-up"])
    #expect(store.hostBridgeCapabilityState(for: "codex") == .ready)
    #expect(store.lastAction == "Enabled Codex host bridge")
  }

  @Test("Host bridge disable agent-tui requires force while sessions are active")
  func setHostBridgeCapabilityDisableRequiresForce() async {
    let client = RecordingHarnessClient()
    client.configureHostBridgeReconfigureError(
      HarnessMonitorAPIError.server(
        code: 409,
        message: "agent-tui capability has 1 active session(s); rerun with --force to stop them first"
      )
    )
    let store = await makeBootstrappedStore(client: client)
    store.daemonStatus = sandboxedStatus(
      hostBridge: HostBridgeManifest(
        running: true,
        socketPath: "/tmp/bridge.sock",
        capabilities: [
          "agent-tui": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "unix",
            endpoint: "/tmp/bridge.sock",
            metadata: ["active_sessions": "1"]
          )
        ]
      )
    )

    let result = await store.setHostBridgeCapability("agent-tui", enabled: false)

    #expect(
      result
        == .requiresForce(
          "agent-tui capability has 1 active session(s); rerun with --force to stop them first"
        )
    )
    #expect(
      client.recordedCalls()
        == [.reconfigureHostBridge(enable: [], disable: ["agent-tui"], force: false)]
    )
    #expect(store.lastError == nil)
    #expect(store.hostBridgeCapabilityState(for: "agent-tui") == .ready)
  }

  @Test("External host bridge reconfigure 404 asks to restart the dev daemon")
  func setHostBridgeCapabilityExternal404SurfacesRestartGuidance() async {
    let staleClient = RecordingHarnessClient()
    staleClient.configureHostBridgeReconfigureError(
      HarnessMonitorAPIError.server(code: 404, message: "Not Found")
    )
    let daemon = HostBridgeRecoveryDaemonController(initialClient: staleClient)
    let store = HarnessMonitorStore(daemonController: daemon, daemonOwnership: .external)
    await store.bootstrap()
    store.daemonStatus = sandboxedStatus(
      hostBridge: HostBridgeManifest(
        running: true,
        socketPath: "/tmp/bridge.sock",
        capabilities: [:]
      )
    )

    let result = await store.setHostBridgeCapability("agent-tui", enabled: true)

    #expect(result == .failed)
    #expect(store.lastError?.contains("Restart `harness daemon dev` and try again.") == true)
    #expect(await daemon.recordedOperations() == ["warm-up"])
  }

  @Test("Host bridge enable clears stale excluded state when the bridge is no longer running")
  func setHostBridgeCapabilityEnableWhenBridgeStoppedFallsBackToStart() async {
    let client = RecordingHarnessClient()
    client.configureHostBridgeReconfigureError(
      HarnessMonitorAPIError.server(code: 400, message: "bridge is not running")
    )
    let store = await makeBootstrappedStore(client: client)
    store.daemonStatus = sandboxedStatus(
      hostBridge: HostBridgeManifest(
        running: true,
        socketPath: "/tmp/bridge.sock",
        capabilities: [:]
      )
    )
    store.hostBridgeCapabilityIssues["agent-tui"] = .excluded

    let result = await store.setHostBridgeCapability("agent-tui", enabled: true)

    #expect(result == .failed)
    #expect(store.lastError == "The shared host bridge is not running. Start it and try again.")
    #expect(store.hostBridgeCapabilityState(for: "agent-tui") == .unavailable)
    #expect(store.hostBridgeStartCommand(for: "agent-tui") == "harness bridge start")
    #expect(store.daemonStatus?.manifest?.hostBridge.running == false)
  }

  @Test("Forced agent-tui disable removes capability and clears local sessions")
  func setHostBridgeCapabilityDisableForceUpdatesManifest() async {
    let client = RecordingHarnessClient()
    let runningTui = client.agentTuiFixture()
    client.configureAgentTuis([runningTui], for: PreviewFixtures.summary.sessionId)
    client.configureHostBridgeStatusReport(
      BridgeStatusReport(
        running: true,
        socketPath: "/tmp/bridge.sock",
        pid: 4321,
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
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.daemonStatus = sandboxedStatus(
      hostBridge: HostBridgeManifest(
        running: true,
        socketPath: "/tmp/bridge.sock",
        capabilities: [
          "agent-tui": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "unix",
            endpoint: "/tmp/bridge.sock",
            metadata: ["active_sessions": "1"]
          ),
          "codex": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "websocket",
            endpoint: "ws://127.0.0.1:4500"
          ),
        ]
      )
    )
    await store.refreshSelectedAgentTuis()

    let result = await store.setHostBridgeCapability("agent-tui", enabled: false, force: true)

    #expect(result == .success)
    #expect(
      client.recordedCalls()
        == [.reconfigureHostBridge(enable: [], disable: ["agent-tui"], force: true)]
    )
    #expect(store.hostBridgeCapabilityState(for: "agent-tui") == .excluded)
    #expect(store.selectedAgentTuis.isEmpty)
    #expect(store.selectedAgentTui == nil)
    #expect(store.lastAction == "Disabled Agent TUI host bridge")
  }

  private func sandboxedStatus(hostBridge: HostBridgeManifest) -> DaemonStatusReport {
    DaemonStatusReport(
      manifest: DaemonManifest(
        version: "19.2.1",
        pid: 111,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-04-11T09:00:00Z",
        tokenPath: "/tmp/token",
        sandboxed: true,
        hostBridge: hostBridge
      ),
      launchAgent: LaunchAgentStatus(
        installed: true,
        loaded: true,
        label: "io.harness.daemon",
        path: "/tmp/io.harness.daemon.plist"
      ),
      projectCount: 1,
      sessionCount: 1,
      diagnostics: DaemonDiagnostics(
        daemonRoot: "/tmp/harness/daemon",
        manifestPath: "/tmp/harness/daemon/manifest.json",
        authTokenPath: "/tmp/token",
        authTokenPresent: true,
        eventsPath: "/tmp/harness/daemon/events.jsonl",
        databasePath: "/tmp/harness/daemon/harness.db",
        databaseSizeBytes: 1_024,
        lastEvent: nil
      )
    )
  }
}

actor HostBridgeRecoveryDaemonController: DaemonControlling {
  private let initialClient: any HarnessMonitorClientProtocol
  private let restartedClient: (any HarnessMonitorClientProtocol)?
  private var warmUpCount = 0
  private var operations: [String] = []

  init(
    initialClient: any HarnessMonitorClientProtocol,
    restartedClient: (any HarnessMonitorClientProtocol)? = nil
  ) {
    self.initialClient = initialClient
    self.restartedClient = restartedClient
  }

  func bootstrapClient() async throws -> any HarnessMonitorClientProtocol {
    initialClient
  }

  func stopDaemon() async throws -> String {
    operations.append("stop")
    return "stopped"
  }

  func daemonStatus() async throws -> DaemonStatusReport {
    DaemonStatusReport(
      manifest: DaemonManifest(
        version: "19.2.1",
        pid: 111,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-04-11T09:00:00Z",
        tokenPath: "/tmp/token",
        sandboxed: true,
        hostBridge: HostBridgeManifest()
      ),
      launchAgent: LaunchAgentStatus(
        installed: true,
        loaded: true,
        label: "io.harness.daemon",
        path: "/tmp/io.harness.daemon.plist"
      ),
      projectCount: 1,
      sessionCount: 1,
      diagnostics: DaemonDiagnostics(
        daemonRoot: "/tmp/harness/daemon",
        manifestPath: "/tmp/harness/daemon/manifest.json",
        authTokenPath: "/tmp/token",
        authTokenPresent: true,
        eventsPath: "/tmp/harness/daemon/events.jsonl",
        databasePath: "/tmp/harness/daemon/harness.db",
        databaseSizeBytes: 1_024,
        lastEvent: nil
      )
    )
  }

  func installLaunchAgent() async throws -> String { "/tmp/io.harness.daemon.plist" }

  func removeLaunchAgent() async throws -> String { "removed" }

  func registerLaunchAgent() async throws -> DaemonLaunchAgentRegistrationState {
    operations.append("register")
    return .enabled
  }

  func launchAgentRegistrationState() async -> DaemonLaunchAgentRegistrationState {
    .enabled
  }

  func launchAgentSnapshot() async -> LaunchAgentStatus {
    LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist"
    )
  }

  func awaitLaunchAgentState(
    _ target: DaemonLaunchAgentRegistrationState,
    timeout: Duration
  ) async throws {}

  func awaitManifestWarmUp(
    timeout: Duration
  ) async throws -> any HarnessMonitorClientProtocol {
    operations.append("warm-up")
    warmUpCount += 1
    if warmUpCount == 1 {
      return initialClient
    }
    return restartedClient ?? initialClient
  }

  func recordedOperations() -> [String] {
    operations
  }
}
