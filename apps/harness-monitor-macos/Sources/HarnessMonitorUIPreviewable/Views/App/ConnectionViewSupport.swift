import HarnessMonitorKit
import SwiftUI

extension ConnectionQuality {
  var themeColor: Color {
    switch self {
    case .excellent, .good:
      HarnessMonitorTheme.success
    case .degraded:
      HarnessMonitorTheme.caution
    case .poor, .disconnected:
      HarnessMonitorTheme.danger
    }
  }
}

extension ConnectionMetrics {
  var showsSidebarFooterTint: Bool {
    connectedSince != nil
  }

  var sidebarFooterTint: Color? {
    showsSidebarFooterTint ? latencyTint : nil
  }

  var latencyTint: Color {
    guard transportLatencyMs != nil else {
      return HarnessMonitorTheme.ink
    }
    return transportQuality.themeColor
  }
}
