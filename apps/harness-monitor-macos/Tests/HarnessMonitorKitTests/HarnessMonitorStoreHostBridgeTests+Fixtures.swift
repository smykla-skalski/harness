@testable import HarnessMonitorKit

func sandboxedStatus(hostBridge: HostBridgeManifest) -> DaemonStatusReport {
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

  func launchAgentRegistrationState() async -> DaemonLaunchAgentRegistrationState { .enabled }

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

  func performDeferredManagedLaunchAgentRefreshIfNeeded() async -> Bool { false }
  func recordedOperations() -> [String] { operations }
}
