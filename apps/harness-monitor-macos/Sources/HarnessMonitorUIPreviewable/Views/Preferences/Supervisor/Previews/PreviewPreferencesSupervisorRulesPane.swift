import HarnessMonitorKit
import SwiftData
import SwiftUI

#Preview("Supervisor Rules Pane") {
  PreferencesSupervisorRulesPane(store: PreferencesPreviewSupport.makeStore())
    .frame(width: 600, height: 400)
}
