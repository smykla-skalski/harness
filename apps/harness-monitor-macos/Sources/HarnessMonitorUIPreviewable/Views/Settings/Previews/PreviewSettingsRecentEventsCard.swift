import HarnessMonitorKit
import SwiftUI

#Preview("Settings Recent Events") {
  Form {
    SettingsRecentEventsSection(events: SettingsPreviewSupport.recentEvents)
  }
  .settingsDetailFormStyle()
  .frame(width: 560)
}

#Preview("Settings Recent Events Empty") {
  Form {
    SettingsRecentEventsSection(events: [])
  }
  .settingsDetailFormStyle()
  .frame(width: 560)
}
