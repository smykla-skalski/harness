import HarnessMonitorKit
import SwiftUI

#Preview("Settings Host Bridge Section") {
  let store = SettingsPreviewSupport.makeStore()

  SettingsHostBridgeSection(store: store)
    .frame(width: 720)
}
