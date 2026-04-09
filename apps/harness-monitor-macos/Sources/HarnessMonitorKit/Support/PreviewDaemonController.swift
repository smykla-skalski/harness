import Foundation

public actor PreviewDaemonController: DaemonControlling {
  public enum Mode: Sendable {
    case dashboardLanding
    case populated
    case overflow
    case signalRegression
    case singleAgent
    case empty
  }

  private let fixtures: PreviewHarnessClient.Fixtures
  private var isDaemonRunning: Bool
  private var isLaunchAgentInstalled: Bool

  public init(mode: Mode = .populated) {
    let fixtures =
      switch mode {
      case .dashboardLanding:
        PreviewHarnessClient.Fixtures.dashboardLanding
      case .populated:
        PreviewHarnessClient.Fixtures.populated
      case .overflow:
        PreviewHarnessClient.Fixtures.overflow
      case .signalRegression:
        PreviewHarnessClient.Fixtures.signalRegression
      case .singleAgent:
        PreviewHarnessClient.Fixtures.singleAgent
      case .empty:
        PreviewHarnessClient.Fixtures.empty
      }

    self.fixtures = fixtures
    self.isDaemonRunning = mode != .empty
    self.isLaunchAgentInstalled = mode != .empty
  }

  public func bootstrapClient() async throws -> any HarnessMonitorClientProtocol {
    guard isDaemonRunning else {
      throw DaemonControlError.daemonOffline
    }
    return makeClient()
  }

  public func startDaemonClient() async throws -> any HarnessMonitorClientProtocol {
    isDaemonRunning = true
    return makeClient()
  }

  public func stopDaemon() async throws -> String {
    isDaemonRunning = false
    return "stopped"
  }

  public func daemonStatus() async throws -> DaemonStatusReport {
    makeStatusReport()
  }

  public func installLaunchAgent() async throws -> String {
    isLaunchAgentInstalled = true
    return Self.launchAgentPath
  }

  public func removeLaunchAgent() async throws -> String {
    isLaunchAgentInstalled = false
    return "removed"
  }

  private func makeClient() -> PreviewHarnessClient {
    PreviewHarnessClient(
      fixtures: fixtures,
      isLaunchAgentInstalled: isLaunchAgentInstalled
    )
  }

  private func makeStatusReport() -> DaemonStatusReport {
    DaemonStatusReport(
      manifest: DaemonManifest(
        version: fixtures.health.version,
        pid: fixtures.health.pid,
        endpoint: fixtures.health.endpoint,
        startedAt: fixtures.health.startedAt,
        tokenPath: "/Users/example/Library/Application Support/harness/daemon/auth-token"
      ),
      launchAgent: LaunchAgentStatus(
        installed: isLaunchAgentInstalled,
        loaded: isDaemonRunning && isLaunchAgentInstalled,
        label: "io.harness.daemon",
        path: Self.launchAgentPath,
        domainTarget: "gui/501",
        serviceTarget: "gui/501/io.harness.daemon",
        state: isDaemonRunning && isLaunchAgentInstalled ? "running" : nil,
        pid: isDaemonRunning && isLaunchAgentInstalled ? fixtures.health.pid : nil,
        lastExitStatus: isDaemonRunning && isLaunchAgentInstalled ? 0 : nil
      ),
      projectCount: fixtures.projects.count,
      sessionCount: fixtures.sessions.count,
      diagnostics: DaemonDiagnostics(
        daemonRoot: "/Users/example/Library/Application Support/harness/daemon",
        manifestPath: "/Users/example/Library/Application Support/harness/daemon/manifest.json",
        authTokenPath: "/Users/example/Library/Application Support/harness/daemon/auth-token",
        authTokenPresent: true,
        eventsPath: "/Users/example/Library/Application Support/harness/daemon/events.jsonl",
        databasePath: "/Users/example/Library/Application Support/harness/daemon/harness.db",
        databaseSizeBytes: isDaemonRunning ? 1_740_800 : 0,
        lastEvent: makeLastEvent()
      )
    )
  }

  private func makeLastEvent() -> DaemonAuditEvent? {
    guard isDaemonRunning, let firstSession = fixtures.sessions.first else {
      return nil
    }

    return DaemonAuditEvent(
      recordedAt: "2026-03-28T14:18:00Z",
      level: "info",
      message: "indexed session \(firstSession.sessionId)"
    )
  }
}

private extension PreviewDaemonController {
  static let launchAgentPath = "/Users/example/Library/LaunchAgents/io.harness.daemon.plist"
}
