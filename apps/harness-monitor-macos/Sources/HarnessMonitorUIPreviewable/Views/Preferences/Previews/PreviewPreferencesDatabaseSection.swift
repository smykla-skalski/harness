import HarnessMonitorKit
import SwiftUI

#Preview("Preferences Database Section") {
  PreferencesDatabaseSection(
    store: PreferencesPreviewSupport.makeStore()
  )
  .frame(width: 720)
}
