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

enum SidebarFooterGlassTintStopRole: Equatable {
  case connection
  case token(SidebarFooterStatusTone)

  func color(connectionTint: Color) -> Color {
    switch self {
    case .connection:
      connectionTint
    case .token(let tone):
      tone.color
    }
  }
}

struct SidebarFooterGlassTintStop: Equatable {
  let role: SidebarFooterGlassTintStopRole
  let location: Double
}

struct SidebarFooterGlassTintBlend: Equatable {
  let stops: [SidebarFooterGlassTintStop]

  init(state: SidebarFooterStatusStripState) {
    let tokenRoles = [state.bridge?.tone, state.mcp?.tone].compactMap(\.self).map {
      SidebarFooterGlassTintStopRole.token($0)
    }

    switch tokenRoles.count {
    case 0:
      stops = [
        SidebarFooterGlassTintStop(role: .connection, location: 0),
        SidebarFooterGlassTintStop(role: .connection, location: 1),
      ]
    case 1:
      stops = [
        SidebarFooterGlassTintStop(role: .connection, location: 0),
        SidebarFooterGlassTintStop(role: .connection, location: 0.44),
        SidebarFooterGlassTintStop(role: tokenRoles[0], location: 1),
      ]
    default:
      stops = [
        SidebarFooterGlassTintStop(role: .connection, location: 0),
        SidebarFooterGlassTintStop(role: .connection, location: 0.38),
        SidebarFooterGlassTintStop(role: tokenRoles[0], location: 0.66),
        SidebarFooterGlassTintStop(role: tokenRoles[1], location: 1),
      ]
    }
  }

  var hasTrailingTint: Bool {
    stops.count > 2
  }

  func gradient(connectionTint: Color) -> LinearGradient {
    LinearGradient(
      stops: stops.map {
        Gradient.Stop(
          color: $0.role.color(connectionTint: connectionTint),
          location: $0.location
        )
      },
      startPoint: .leading,
      endPoint: .trailing
    )
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
  private static let glassCornerRadius = HarnessMonitorTheme.cornerRadiusMD
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

  private var connectionTint: Color {
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

  private var backgroundTintBlend: SidebarFooterGlassTintBlend {
    SidebarFooterGlassTintBlend(state: statusStripState)
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
    .background {
      SidebarFooterGlassTintWash(
        connectionTint: connectionTint,
        blend: backgroundTintBlend,
        cornerRadius: Self.glassCornerRadius
      )
    }
    .harnessFloatingControlGlass(
      cornerRadius: Self.glassCornerRadius,
      tint: connectionTint
    )
    .padding(HarnessMonitorTheme.itemSpacing)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarFooter)
  }
}

private struct SidebarFooterGlassTintWash: View {
  let connectionTint: Color
  let blend: SidebarFooterGlassTintBlend
  let cornerRadius: CGFloat
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var fillOpacity: Double {
    if reduceTransparency {
      return colorSchemeContrast == .increased ? 0.3 : 0.24
    }
    return colorSchemeContrast == .increased ? 0.24 : 0.18
  }

  @ViewBuilder
  var body: some View {
    if blend.hasTrailingTint {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(blend.gradient(connectionTint: connectionTint).opacity(fillOpacity))
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
  }
}

private struct SidebarFooterStatusStrip: View {
  let state: SidebarFooterStatusStripState
  private static let separatorSpacing: CGFloat = 3

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Self.separatorSpacing) {
      if let bridge = state.bridge {
        SidebarFooterStatusWord(token: bridge)
      }
      if state.showsSeparator {
        Text(verbatim: "·")
          .scaledFont(.system(.caption2, design: .rounded, weight: .semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk.opacity(0.55))
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

#Preview("Sidebar Footer Variants") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)

  VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
    SidebarFooterPreviewVariant(
      title: "Managed unavailable",
      accessory: SidebarFooterAccessory(
        metrics: store.connectionMetrics,
        daemonOwnership: .managed,
        bridgeRunning: false,
        mcpStatus: HarnessMonitorMCPStatusSnapshot(
          runtimeState: .disabled,
          recoveryStatus: nil
        ),
        isMCPRegistryHostEnabled: true
      )
    )
    SidebarFooterPreviewVariant(
      title: "Healthy services",
      accessory: SidebarFooterAccessory(
        metrics: store.connectionMetrics,
        daemonOwnership: .managed,
        bridgeRunning: true,
        mcpStatus: HarnessMonitorMCPStatusSnapshot(
          runtimeState: .healthy(socketPath: "/tmp/harness-mcp.sock"),
          recoveryStatus: nil
        ),
        isMCPRegistryHostEnabled: true
      )
    )
    SidebarFooterPreviewVariant(
      title: "Mixed tint blend",
      accessory: SidebarFooterAccessory(
        metrics: store.connectionMetrics,
        daemonOwnership: .managed,
        bridgeRunning: true,
        mcpStatus: HarnessMonitorMCPStatusSnapshot(
          runtimeState: .disabled,
          recoveryStatus: nil
        ),
        isMCPRegistryHostEnabled: true
      )
    )
    SidebarFooterPreviewVariant(
      title: "Mixed tint blend — WS degraded",
      accessory: SidebarFooterAccessory(
        metrics: sidebarFooterPreviewConnectionMetrics(latencyMs: 320, messagesPerSecond: 4.1),
        daemonOwnership: .managed,
        bridgeRunning: true,
        mcpStatus: HarnessMonitorMCPStatusSnapshot(
          runtimeState: .disabled,
          recoveryStatus: nil
        ),
        isMCPRegistryHostEnabled: true
      )
    )
    SidebarFooterPreviewVariant(
      title: "Mixed tint blend — WS poor",
      accessory: SidebarFooterAccessory(
        metrics: sidebarFooterPreviewConnectionMetrics(latencyMs: 820, messagesPerSecond: 1.8),
        daemonOwnership: .managed,
        bridgeRunning: true,
        mcpStatus: HarnessMonitorMCPStatusSnapshot(
          runtimeState: .disabled,
          recoveryStatus: nil
        ),
        isMCPRegistryHostEnabled: true
      )
    )
    SidebarFooterPreviewVariant(
      title: "Connection only",
      accessory: SidebarFooterAccessory(
        metrics: .initial,
        daemonOwnership: .external,
        bridgeRunning: false,
        mcpStatus: HarnessMonitorMCPStatusSnapshot(
          runtimeState: .disabled,
          recoveryStatus: nil
        ),
        isMCPRegistryHostEnabled: false
      )
    )
  }
  .padding(24)
  .frame(width: 360)
}

private struct SidebarFooterPreviewVariant: View {
  let title: String
  let accessory: SidebarFooterAccessory

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(title)
        .scaledFont(.system(.caption, design: .rounded, weight: .semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      accessory
        .frame(width: 280)
    }
  }
}

private func sidebarFooterPreviewConnectionMetrics(
  latencyMs: Int,
  messagesPerSecond: Double
) -> ConnectionMetrics {
  ConnectionMetrics(
    transportKind: .webSocket,
    latencyMs: latencyMs,
    averageLatencyMs: latencyMs + 4,
    messagesReceived: 64,
    messagesSent: 64,
    messagesPerSecond: messagesPerSecond,
    connectedSince: .now.addingTimeInterval(-900),
    lastMessageAt: .now,
    reconnectAttempt: 0,
    reconnectCount: 0,
    isFallback: false,
    fallbackReason: nil
  )
}
