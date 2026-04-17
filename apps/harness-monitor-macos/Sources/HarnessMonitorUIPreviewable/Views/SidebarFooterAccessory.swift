import HarnessMonitorKit
import SwiftUI

public struct SidebarFooterAccessory: View {
  public let metrics: ConnectionMetrics

  public init(metrics: ConnectionMetrics) {
    self.metrics = metrics
  }

  private var tint: Color {
    metrics.latencyTint
  }

  public var body: some View {
    ConnectionToolbarBadge(metrics: metrics)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, HarnessMonitorTheme.itemSpacing)
      .padding(.horizontal, HarnessMonitorTheme.itemSpacing)
      .harnessFloatingControlGlass(
        cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
        tint: tint
      )
      .padding(HarnessMonitorTheme.itemSpacing)
      .accessibilityIdentifier("harness.sidebar.connection-pill")
  }
}

#Preview("Sidebar Footer - Live") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)

  SidebarFooterAccessory(metrics: store.connectionMetrics)
    .padding(20)
    .frame(width: 280)
}

#Preview("Sidebar Footer - Disconnected") {
  SidebarFooterAccessory(metrics: .initial)
    .padding(20)
    .frame(width: 280)
}
