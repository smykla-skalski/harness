import HarnessMonitorKit
import SwiftUI

#Preview("Settings Database Section") {
  SettingsDatabaseSection(
    store: SettingsPreviewSupport.makeStore()
  )
  .frame(width: 720)
}
