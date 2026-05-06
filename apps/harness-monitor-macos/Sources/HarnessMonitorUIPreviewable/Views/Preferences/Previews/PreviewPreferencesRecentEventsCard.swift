import HarnessMonitorKit
import SwiftUI

#Preview("Preferences Recent Events") {
  Form {
    PreferencesRecentEventsSection(events: PreferencesPreviewSupport.recentEvents)
  }
  .preferencesDetailFormStyle()
  .frame(width: 560)
}

#Preview("Preferences Recent Events Empty") {
  Form {
    PreferencesRecentEventsSection(events: [])
  }
  .preferencesDetailFormStyle()
  .frame(width: 560)
}
