import HarnessMonitorKit
import SwiftUI

struct ToolbarDaemonStatusDot: View {
  let connectionState: HarnessMonitorStore.ConnectionState
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  var body: some View {
    Circle()
      .fill(statusColor.opacity(fillOpacity))
      .frame(width: 10, height: 10)
      .background {
        Circle()
          .strokeBorder(statusColor.opacity(strokeOpacity), lineWidth: 1)
      }
      .accessibilityHidden(true)
  }

  private var statusColor: Color {
    switch connectionState {
    case .online: HarnessMonitorTheme.success
    case .connecting: HarnessMonitorTheme.caution
    case .idle: HarnessMonitorTheme.accent
    case .offline: HarnessMonitorTheme.danger
    }
  }

  private var fillOpacity: Double {
    if reduceTransparency {
      return colorSchemeContrast == .increased ? 0.88 : 0.8
    }
    return colorSchemeContrast == .increased ? 0.76 : 0.66
  }

  private var strokeOpacity: Double {
    colorSchemeContrast == .increased ? 0.92 : 0.72
  }
}
