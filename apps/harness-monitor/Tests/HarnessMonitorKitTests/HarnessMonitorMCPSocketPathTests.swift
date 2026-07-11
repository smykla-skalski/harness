import Foundation
import HarnessMonitorKit
import Testing

@Suite("Harness Monitor MCP socket paths")
struct HarnessMonitorMCPSocketPathTests {
  @Test("MCP socket filename stays within realistic Unix socket path limits")
  func mcpSocketFilenameStaysWithinUnixSocketPathLimits() {
    let homeDirectory = URL(fileURLWithPath: "/Users/monitor", isDirectory: true)
    let appGroupDirectory =
      homeDirectory
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Group Containers", isDirectory: true)
      .appendingPathComponent(
        HarnessMonitorMCPSettingsDefaults.appGroupIdentifier,
        isDirectory: true
      )
    let socketPath =
      appGroupDirectory
      .appendingPathComponent(
        HarnessMonitorMCPSettingsDefaults.socketFilename,
        isDirectory: false
      )
    let legacySocketPath =
      appGroupDirectory
      .appendingPathComponent("harness-monitor-mcp.sock", isDirectory: false)

    #expect(HarnessMonitorMCPSettingsDefaults.socketFilename == "mcp.sock")
    #expect(socketPath.path.count < 104)
    #expect(legacySocketPath.path.count > socketPath.path.count)
  }

  @Test("External daemon mode falls back to home-relative app group socket path")
  func externalDaemonModeFallsBackToHomeRelativeAppGroupSocketPath() {
    let homeDirectory = URL(fileURLWithPath: "/Users/monitor", isDirectory: true)
    let appGroup = "Q498EB36N4.io.harnessmonitor.tests.\(UUID().uuidString)"
    let environment = HarnessMonitorEnvironment(
      values: [DaemonOwnership.environmentKey: "1"],
      homeDirectory: homeDirectory,
      bundleURL: nil
    )

    let socketPath = HarnessMonitorMCPSocketPath.resolved(
      appGroup: appGroup,
      filename: "mcp.sock",
      environment: environment
    )

    #expect(
      socketPath
        == homeDirectory
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Group Containers", isDirectory: true)
        .appendingPathComponent(appGroup, isDirectory: true)
        .appendingPathComponent("mcp.sock", isDirectory: false)
    )
  }
}
