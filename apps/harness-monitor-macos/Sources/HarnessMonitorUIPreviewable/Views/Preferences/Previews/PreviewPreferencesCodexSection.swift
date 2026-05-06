import HarnessMonitorKit
import SwiftUI

#Preview("Preferences Host Bridge Section") {
  let store = PreferencesPreviewSupport.makeStore()

  PreferencesHostBridgeSection(store: store)
    .frame(width: 720)
}
