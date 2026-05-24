import HarnessMonitorKit
import SwiftUI

#Preview("Settings Connection Metrics") {
  let store = SettingsPreviewSupport.makeStore()

  Form {
    SettingsConnectionMetrics(
      metrics: store.connectionMetrics,
      events: store.connectionEvents
    )
  }
  .settingsDetailFormStyle()
  .frame(width: 560)
}
