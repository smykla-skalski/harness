import HarnessMonitorKit
import SwiftUI

#Preview("Supervisor Notifications Pane") {
  SettingsSupervisorNotificationsPane(
    notifications: HarnessMonitorUserNotificationController.preview()
  )
  .frame(width: 600, height: 640)
}
