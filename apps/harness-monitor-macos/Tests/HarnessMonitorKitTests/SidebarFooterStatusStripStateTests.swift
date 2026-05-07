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

@Suite("SidebarFooterGlassTintBlend")
struct SidebarFooterGlassTintBlendTests {
  @Test("Hidden footer services keep a uniform connection tint")
  func hiddenFooterServicesKeepUniformConnectionTint() {
    let state = SidebarFooterStatusStripState(
      daemonOwnership: .external,
      bridgeRunning: false,
      mcpStatus: HarnessMonitorMCPStatusSnapshot(
        runtimeState: .disabled,
        recoveryStatus: nil
      ),
      isMCPRegistryHostEnabled: false
    )
    let blend = SidebarFooterGlassTintBlend(state: state)

    #expect(!blend.hasTrailingTint)
    #expect(
      blend.stops == [
        SidebarFooterGlassTintStop(role: .connection, location: 0),
        SidebarFooterGlassTintStop(role: .connection, location: 1),
      ]
    )
  }

  @Test("Managed bridge and MCP feed their token tones into the trailing blend")
  func managedBridgeAndMCPFeedTokenTonesIntoTrailingBlend() {
    let state = SidebarFooterStatusStripState(
      daemonOwnership: .managed,
      bridgeRunning: true,
      mcpStatus: HarnessMonitorMCPStatusSnapshot(
        runtimeState: .disabled,
        recoveryStatus: nil
      ),
      isMCPRegistryHostEnabled: true
    )
    let blend = SidebarFooterGlassTintBlend(state: state)

    #expect(blend.hasTrailingTint)
    #expect(
      blend.stops == [
        SidebarFooterGlassTintStop(role: .connection, location: 0),
        SidebarFooterGlassTintStop(role: .connection, location: 0.38),
        SidebarFooterGlassTintStop(role: .token(.success), location: 0.66),
        SidebarFooterGlassTintStop(role: .token(.muted), location: 1),
      ]
    )
  }

  @Test("Single visible footer token colors the trailing edge")
  func singleVisibleFooterTokenColorsTrailingEdge() {
    let state = SidebarFooterStatusStripState(
      daemonOwnership: .external,
      bridgeRunning: false,
      mcpStatus: HarnessMonitorMCPStatusSnapshot(
        runtimeState: .healthy(socketPath: "/tmp/harness-mcp.sock"),
        recoveryStatus: nil
      ),
      isMCPRegistryHostEnabled: true
    )
    let blend = SidebarFooterGlassTintBlend(state: state)

    #expect(blend.hasTrailingTint)
    #expect(
      blend.stops == [
        SidebarFooterGlassTintStop(role: .connection, location: 0),
        SidebarFooterGlassTintStop(role: .connection, location: 0.44),
        SidebarFooterGlassTintStop(role: .token(.success), location: 1),
      ]
    )
  }
}

@Suite("SidebarFooterConnectionTint")
struct SidebarFooterConnectionTintTests {
  @Test("Disconnected footer renders without a connection tint")
  func disconnectedFooterRendersWithoutAConnectionTint() {
    #expect(!ConnectionMetrics.initial.showsSidebarFooterTint)
  }

  @Test("Connected footer keeps the connection tint")
  func connectedFooterKeepsTheConnectionTint() {
    var metrics = ConnectionMetrics.initial
    metrics.transportKind = .webSocket
    metrics.transportLatencyMs = 42
    metrics.connectedSince = .now
    metrics.lastMessageAt = .now

    #expect(metrics.showsSidebarFooterTint)
  }

  @Test("Connecting footer stays muted until latency is measured")
  func connectingFooterStaysMutedUntilLatencyIsMeasured() {
    var metrics = ConnectionMetrics.initial
    metrics.transportKind = .webSocket
    metrics.connectedSince = .now

    #expect(metrics.usesMutedConnectionChrome)
    #expect(!metrics.showsSidebarFooterTint)
  }
}
