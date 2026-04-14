import Foundation

@testable import HarnessMonitorKit

actor DelayedWarmUpDaemonController: DaemonControlling {
  private let client: any HarnessMonitorClientProtocol
  private let warmUpDelay: Duration

  init(
    client: any HarnessMonitorClientProtocol = PreviewHarnessClient(),
    warmUpDelay: Duration
  ) {
    self.client = client
    self.warmUpDelay = warmUpDelay
  }

  func bootstrapClient() async throws -> any HarnessMonitorClientProtocol {
    client
  }

  func stopDaemon() async throws -> String {
    "stopped"
  }

  func daemonStatus() async throws -> DaemonStatusReport {
    DaemonStatusReport(
      manifest: DaemonManifest(
        version: "20.6.10",
        pid: 111,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-04-13T20:58:00Z",
        tokenPath: "/tmp/token"
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

  func installLaunchAgent() async throws -> String {
    "launch agent installed"
  }

  func removeLaunchAgent() async throws -> String {
    "launch agent removed"
  }

  func registerLaunchAgent() async throws -> DaemonLaunchAgentRegistrationState {
    .enabled
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
    try await Task.sleep(for: warmUpDelay)
    return client
  }
}
