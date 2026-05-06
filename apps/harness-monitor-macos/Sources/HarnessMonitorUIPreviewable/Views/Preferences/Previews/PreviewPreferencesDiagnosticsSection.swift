import HarnessMonitorKit
import SwiftUI

#Preview("Preferences Diagnostics Section") {
  let store = PreferencesPreviewSupport.makeStore()

  PreferencesDiagnosticsSection(
    snapshot: PreferencesDiagnosticsSnapshot(store: store)
  )
  .frame(width: 720)
}
