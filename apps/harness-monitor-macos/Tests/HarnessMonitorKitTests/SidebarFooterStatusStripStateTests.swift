import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("SidebarFooterStatusStripState")
struct SidebarFooterStatusStripStateTests {
  @Test("Managed daemon shows stopped bridge and unavailable MCP by default")
  func managedDaemonShowsStoppedBridgeAndUnavailableMCP() {
    let state = SidebarFooterStatusStripState(
      daemonOwnership: .managed,
      bridgeRunning: false,
      mcpStatus: HarnessMonitorMCPStatusSnapshot(
        runtimeState: .disabled,
        recoveryStatus: nil
      ),
      isMCPRegistryHostEnabled: true
    )

    #expect(state.bridge?.label == "BRIDGE")
    #expect(state.bridge?.tone == .muted)
    #expect(state.mcp?.label == "MCP")
    #expect(state.mcp?.tone == .muted)
    #expect(state.showsSeparator)
    #expect(state.stateMarkerValue == "bridge=stopped, mcp=unavailable")
  }

  @Test("Healthy managed daemon shows green BRIDGE and MCP")
  func healthyManagedDaemonShowsSuccessTokens() {
    let state = SidebarFooterStatusStripState(
      daemonOwnership: .managed,
      bridgeRunning: true,
      mcpStatus: HarnessMonitorMCPStatusSnapshot(
        runtimeState: .healthy(socketPath: "/tmp/harness-mcp.sock"),
        recoveryStatus: nil
      ),
      isMCPRegistryHostEnabled: true
    )

    #expect(state.bridge?.tone == .success)
    #expect(state.mcp?.tone == .success)
    #expect(state.stateMarkerValue == "bridge=running, mcp=ready")
  }

  @Test("External daemon hides BRIDGE and separator")
  func externalDaemonHidesBridge() {
    let state = SidebarFooterStatusStripState(
      daemonOwnership: .external,
      bridgeRunning: true,
      mcpStatus: HarnessMonitorMCPStatusSnapshot(
        runtimeState: .healthy(socketPath: "/tmp/harness-mcp.sock"),
        recoveryStatus: nil
      ),
      isMCPRegistryHostEnabled: true
    )

    #expect(state.bridge == nil)
    #expect(state.mcp?.label == "MCP")
    #expect(!state.showsSeparator)
    #expect(state.stateMarkerValue == "bridge=hidden, mcp=ready")
  }

  @Test("Disabled MCP setting hides MCP and separator")
  func disabledMCPSettingHidesMCPAndSeparator() {
    let state = SidebarFooterStatusStripState(
      daemonOwnership: .managed,
      bridgeRunning: true,
      mcpStatus: HarnessMonitorMCPStatusSnapshot(
        runtimeState: .healthy(socketPath: "/tmp/harness-mcp.sock"),
        recoveryStatus: nil
      ),
      isMCPRegistryHostEnabled: false
    )

    #expect(state.bridge?.label == "BRIDGE")
    #expect(state.mcp == nil)
    #expect(!state.showsSeparator)
    #expect(state.stateMarkerValue == "bridge=running, mcp=hidden")
  }
}
