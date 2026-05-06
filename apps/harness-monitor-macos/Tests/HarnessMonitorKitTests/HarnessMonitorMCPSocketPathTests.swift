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
    #expect(legacySocketPath.path.count >= 104)
  }
}
