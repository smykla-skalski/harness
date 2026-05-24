import HarnessMonitorKit
import SwiftUI

#Preview("Settings Diagnostics Section") {
  let store = SettingsPreviewSupport.makeStore()

  SettingsDiagnosticsSection(
    snapshot: SettingsDiagnosticsSnapshot(store: store)
  )
  .frame(width: 720)
}
