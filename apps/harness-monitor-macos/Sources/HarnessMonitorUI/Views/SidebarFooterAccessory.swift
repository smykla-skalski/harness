import HarnessMonitorKit
import SwiftUI

struct SidebarFooterAccessory: View {
  let metrics: ConnectionMetrics

  var body: some View {
    ConnectionToolbarBadge(metrics: metrics)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, HarnessMonitorTheme.itemSpacing)
      .padding(.horizontal, HarnessMonitorTheme.itemSpacing)
      .harnessFloatingControlGlass(
        cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
        tint: HarnessMonitorTheme.ink
      )
      .padding(HarnessMonitorTheme.itemSpacing)
  }
}
