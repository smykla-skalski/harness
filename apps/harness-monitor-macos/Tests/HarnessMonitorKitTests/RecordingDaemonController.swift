import Foundation

@testable import HarnessMonitorKit

actor RecordingDaemonController: DaemonControlling {
  private let client: any HarnessMonitorClientProtocol
  private var launchAgentInstalled: Bool
  private var lastEventMessage = "daemon ready"

  init(
    client: any HarnessMonitorClientProtocol = PreviewHarnessClient(),
    launchAgentInstalled: Bool = true
  ) {
    self.client = client
    self.launchAgentInstalled = launchAgentInstalled
  }

  func bootstrapClient() async throws -> any HarnessMonitorClientProtocol {
    client
  }

  func registerLaunchAgent() async throws -> DaemonLaunchAgentRegistrationState {
    launchAgentInstalled = true
    lastEventMessage = "launch agent installed"
    return .enabled
  }

  func launchAgentRegistrationState() async -> DaemonLaunchAgentRegistrationState {
    launchAgentInstalled ? .enabled : .notRegistered
  }

  func launchAgentSnapshot() async -> LaunchAgentStatus {
    LaunchAgentStatus(
      installed: launchAgentInstalled,
      loaded: launchAgentInstalled,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist",
      domainTarget: "gui/501",
      serviceTarget: "gui/501/io.harness.daemon",
      state: launchAgentInstalled ? "running" : nil,
      pid: launchAgentInstalled ? 4_242 : nil,
      lastExitStatus: launchAgentInstalled ? 0 : nil
    )
  }

  func awaitLaunchAgentState(
    _ target: DaemonLaunchAgentRegistrationState,
    timeout: Duration
  ) async throws {}

  func awaitManifestWarmUp(
    timeout: Duration
  ) async throws -> any HarnessMonitorClientProtocol {
    client
  }

  func stopDaemon() async throws -> String {
    lastEventMessage = "daemon stopped"
    return "stopped"
  }

  func daemonStatus() async throws -> DaemonStatusReport {
    DaemonStatusReport(
      manifest: DaemonManifest(
        version: "14.5.0",
        pid: 111,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        tokenPath: "/tmp/token"
      ),
      launchAgent: LaunchAgentStatus(
        installed: launchAgentInstalled,
        loaded: launchAgentInstalled,
        label: "io.harness.daemon",
        path: "/tmp/io.harness.daemon.plist",
        domainTarget: "gui/501",
        serviceTarget: "gui/501/io.harness.daemon",
        state: launchAgentInstalled ? "running" : nil,
        pid: launchAgentInstalled ? 4_242 : nil,
        lastExitStatus: launchAgentInstalled ? 0 : nil
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
        databaseSizeBytes: 1_740_800,
        lastEvent: DaemonAuditEvent(
          recordedAt: "2026-03-28T14:00:00Z",
          level: "info",
          message: lastEventMessage
        )
      )
    )
  }

  func installLaunchAgent() async throws -> String {
    launchAgentInstalled = true
    lastEventMessage = "launch agent installed"
    return "/tmp/io.harness.daemon.plist"
  }

  func removeLaunchAgent() async throws -> String {
    launchAgentInstalled = false
    lastEventMessage = "launch agent removed"
    return "removed"
  }
}
