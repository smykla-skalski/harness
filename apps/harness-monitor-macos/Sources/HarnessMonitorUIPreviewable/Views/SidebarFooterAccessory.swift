import HarnessMonitorKit
import SwiftUI

enum SidebarFooterStatusTone: Equatable {
  case success
  case muted

  var color: Color {
    switch self {
    case .success:
      HarnessMonitorTheme.success
    case .muted:
      HarnessMonitorTheme.secondaryInk
    }
  }
}

struct SidebarFooterStatusToken: Equatable {
  let label: String
  let tone: SidebarFooterStatusTone
  let accessibilityValue: String
  let help: String
}

struct SidebarFooterStatusStripState: Equatable {
  let bridge: SidebarFooterStatusToken?
  let mcp: SidebarFooterStatusToken?

  init(
    daemonOwnership: DaemonOwnership,
    bridgeRunning: Bool,
    mcpStatus: HarnessMonitorMCPStatusSnapshot,
    isMCPRegistryHostEnabled: Bool
  ) {
    if daemonOwnership == .managed {
      bridge = SidebarFooterStatusToken(
        label: "BRIDGE",
        tone: bridgeRunning ? .success : .muted,
        accessibilityValue: bridgeRunning ? "Host bridge running" : "Host bridge stopped",
        help: bridgeRunning ? "Built-in host bridge running." : "Built-in host bridge not running."
      )
    } else {
      bridge = nil
    }

    if isMCPRegistryHostEnabled {
      let isMCPReady: Bool
      if case .healthy = mcpStatus.runtimeState {
        isMCPReady = true
      } else {
        isMCPReady = false
      }
      mcp = SidebarFooterStatusToken(
        label: "MCP",
        tone: isMCPReady ? .success : .muted,
        accessibilityValue: isMCPReady ? "MCP ready" : "MCP unavailable",
        help: mcpStatus.detail
      )
    } else {
      mcp = nil
    }
  }

  var hasVisibleTokens: Bool {
    bridge != nil || mcp != nil
  }

  var showsSeparator: Bool {
    bridge != nil && mcp != nil
  }

  var stateMarkerValue: String {
    "bridge=\(bridgeState), mcp=\(mcpState)"
  }

  var accessibilityValue: String {
    let parts = [bridge?.accessibilityValue, mcp?.accessibilityValue].compactMap(\.self)
    if parts.isEmpty {
      return "No footer service indicators visible"
    }
    return parts.joined(separator: ", ")
  }

  var helpText: String {
    [bridge?.help, mcp?.help].compactMap(\.self).joined(separator: "\n")
  }

  private var bridgeState: String {
    guard let bridge else {
      return "hidden"
    }
    return bridge.tone == .success ? "running" : "stopped"
  }

  private var mcpState: String {
    guard let mcp else {
      return "hidden"
    }
    return mcp.tone == .success ? "ready" : "unavailable"
  }
}

public struct SidebarFooterAccessory: View {
  public let metrics: ConnectionMetrics
  public let daemonOwnership: DaemonOwnership
  public let bridgeRunning: Bool
  public let mcpStatus: HarnessMonitorMCPStatusSnapshot
  public let isMCPRegistryHostEnabled: Bool

  public init(
    metrics: ConnectionMetrics,
    daemonOwnership: DaemonOwnership,
    bridgeRunning: Bool,
    mcpStatus: HarnessMonitorMCPStatusSnapshot,
    isMCPRegistryHostEnabled: Bool
  ) {
    self.metrics = metrics
    self.daemonOwnership = daemonOwnership
    self.bridgeRunning = bridgeRunning
    self.mcpStatus = mcpStatus
    self.isMCPRegistryHostEnabled = isMCPRegistryHostEnabled
  }

  private var tint: Color {
    metrics.latencyTint
  }

  private var statusStripState: SidebarFooterStatusStripState {
    SidebarFooterStatusStripState(
      daemonOwnership: daemonOwnership,
      bridgeRunning: bridgeRunning,
      mcpStatus: mcpStatus,
      isMCPRegistryHostEnabled: isMCPRegistryHostEnabled
    )
  }

  public var body: some View {
    HStack(spacing: HarnessMonitorTheme.itemSpacing) {
      ConnectionToolbarBadge(metrics: metrics)

      if statusStripState.hasVisibleTokens {
        Spacer(minLength: 0)
        SidebarFooterStatusStrip(state: statusStripState)
      }
    }
    .padding(.vertical, HarnessMonitorTheme.itemSpacing)
    .padding(.horizontal, HarnessMonitorTheme.itemSpacing)
    .harnessFloatingControlGlass(
      cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
      tint: tint
    )
    .padding(HarnessMonitorTheme.itemSpacing)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarFooter)
  }
}

private struct SidebarFooterStatusStrip: View {
  let state: SidebarFooterStatusStripState

  private static let separatorSize: CGFloat = 4

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      if let bridge = state.bridge {
        SidebarFooterStatusWord(token: bridge)
      }
      if state.showsSeparator {
        Circle()
          .fill(HarnessMonitorTheme.secondaryInk.opacity(0.45))
          .frame(width: Self.separatorSize, height: Self.separatorSize)
          .accessibilityHidden(true)
      }
      if let mcp = state.mcp {
        SidebarFooterStatusWord(token: mcp)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Footer services")
    .accessibilityValue(state.accessibilityValue)
    .help(state.helpText)
  }
}

private struct SidebarFooterStatusWord: View {
  let token: SidebarFooterStatusToken

  var body: some View {
    Text(token.label)
      .scaledFont(.system(.caption, design: .rounded, weight: .semibold))
      .foregroundStyle(token.tone.color)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .accessibilityHidden(true)
  }
}

#Preview("Sidebar Footer - Managed Unavailable") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)

  SidebarFooterAccessory(
    metrics: store.connectionMetrics,
    daemonOwnership: .managed,
    bridgeRunning: false,
    mcpStatus: HarnessMonitorMCPStatusSnapshot(
      runtimeState: .disabled,
      recoveryStatus: nil
    ),
    isMCPRegistryHostEnabled: true
  )
  .padding(20)
  .frame(width: 280)
}

#Preview("Sidebar Footer - Healthy Services") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)

  SidebarFooterAccessory(
    metrics: store.connectionMetrics,
    daemonOwnership: .managed,
    bridgeRunning: true,
    mcpStatus: HarnessMonitorMCPStatusSnapshot(
      runtimeState: .healthy(socketPath: "/tmp/harness-mcp.sock"),
      recoveryStatus: nil
    ),
    isMCPRegistryHostEnabled: true
  )
  .padding(20)
  .frame(width: 280)
}

#Preview("Sidebar Footer - Connection Only") {
  SidebarFooterAccessory(
    metrics: .initial,
    daemonOwnership: .external,
    bridgeRunning: false,
    mcpStatus: HarnessMonitorMCPStatusSnapshot(
      runtimeState: .disabled,
      recoveryStatus: nil
    ),
    isMCPRegistryHostEnabled: false
  )
  .padding(20)
  .frame(width: 280)
}
