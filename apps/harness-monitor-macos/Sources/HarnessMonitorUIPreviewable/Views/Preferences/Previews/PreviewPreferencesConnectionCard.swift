import HarnessMonitorKit
import SwiftUI

#Preview("Preferences Connection Metrics") {
  let store = PreferencesPreviewSupport.makeStore()

  Form {
    PreferencesConnectionMetrics(
      metrics: store.connectionMetrics,
      events: store.connectionEvents
    )
  }
  .preferencesDetailFormStyle()
  .frame(width: 560)
}
