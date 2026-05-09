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
  var usesMutedConnectionChrome: Bool {
    transportLatencyMs == nil && requestLatencyMs == nil
  }

  var latencyTint: Color {
    if usesMutedConnectionChrome {
      return HarnessMonitorTheme.disabledConnectionChrome
    }
    if transportLatencyMs != nil {
      return transportQuality.themeColor
    }
    return requestQuality.themeColor
  }
}
