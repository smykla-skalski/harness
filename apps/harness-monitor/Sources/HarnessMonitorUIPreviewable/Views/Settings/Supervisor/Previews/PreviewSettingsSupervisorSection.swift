import HarnessMonitorKit
import SwiftUI

#Preview("Settings Supervisor Section — empty") {
  @Previewable @State var selectedPane: SupervisorPaneKey = .rules

  SettingsSupervisorSection(
    store: SettingsPreviewSupport.makeStore(),
    notifications: HarnessMonitorUserNotificationController.preview(),
    selectedPane: $selectedPane
  )
  .frame(width: 640, height: 480)
}
