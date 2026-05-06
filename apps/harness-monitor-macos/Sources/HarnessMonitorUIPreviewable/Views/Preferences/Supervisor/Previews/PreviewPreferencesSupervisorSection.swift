import HarnessMonitorKit
import SwiftUI

#Preview("Preferences Supervisor Section — empty") {
  @Previewable @State var selectedPane: SupervisorPaneKey = .rules

  PreferencesSupervisorSection(
    store: PreferencesPreviewSupport.makeStore(),
    notifications: HarnessMonitorUserNotificationController.preview(),
    selectedPane: $selectedPane
  )
  .frame(width: 640, height: 480)
}
