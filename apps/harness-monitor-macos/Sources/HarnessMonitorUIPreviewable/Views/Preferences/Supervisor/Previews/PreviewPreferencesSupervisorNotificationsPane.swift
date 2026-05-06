import HarnessMonitorKit
import SwiftUI

#Preview("Supervisor Notifications Pane") {
  PreferencesSupervisorNotificationsPane(
    notifications: HarnessMonitorUserNotificationController.preview()
  )
  .frame(width: 600, height: 640)
}
