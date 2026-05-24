import HarnessMonitorKit
import SwiftData
import SwiftUI

#Preview("Supervisor Rules Pane") {
  SettingsSupervisorRulesPane(store: SettingsPreviewSupport.makeStore())
    .frame(width: 600, height: 400)
}
