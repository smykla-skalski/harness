import HarnessMonitorKit
import SwiftUI

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
