import HarnessMonitorKit
import SwiftUI

#Preview("Settings Notifications Section") {
  SettingsNotificationsSection(
    notifications: HarnessMonitorUserNotificationController.preview()
  )
  .frame(width: 720)
}
