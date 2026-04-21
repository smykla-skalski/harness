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
  var latencyTint: Color {
    guard latencyMs != nil else {
      return HarnessMonitorTheme.ink
    }
    return quality.themeColor
  }
}
