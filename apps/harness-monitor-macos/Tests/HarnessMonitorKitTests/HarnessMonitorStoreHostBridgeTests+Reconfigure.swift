import Darwin
import Testing

@testable import HarnessMonitorKit


@MainActor
extension HarnessMonitorStoreHostBridgeTests {
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
    #expect(
      store.daemonStatus?.manifest?.hostBridge.capabilities["codex"]?.endpoint
        == "ws://127.0.0.1:4500")
    #expect(store.currentSuccessFeedbackMessage == "Enabled Codex host bridge")
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
    #expect(store.currentSuccessFeedbackMessage == "Enabled Codex host bridge")
  }

  @Test("Host bridge disable agent-tui requires force while sessions are active")
  func setHostBridgeCapabilityDisableRequiresForce() async {
    let client = RecordingHarnessClient()
    client.configureHostBridgeReconfigureError(
      HarnessMonitorAPIError.server(
        code: 409,
        message:
          "agent-tui capability has 1 active session(s); rerun with --force to stop them first"
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
    #expect(store.currentFailureFeedbackMessage == nil)
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
    #expect(
      store.currentFailureFeedbackMessage?.contains("Restart `harness daemon dev` and try again.")
        == true)
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
    #expect(
      store.currentFailureFeedbackMessage
        == "The shared host bridge is not running. Start it and try again.")
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
    #expect(store.currentSuccessFeedbackMessage == "Disabled Agent TUI host bridge")
  }

}

private func sandboxedStatus(hostBridge: HostBridgeManifest) -> DaemonStatusReport {
  DaemonStatusReport(
    manifest: DaemonManifest(
      version: "19.3.0",
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
