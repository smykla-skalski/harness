import HarnessMonitorKit
import SwiftUI

struct SettingsNotificationsSnapshot: Equatable, Sendable {
  let settingsSnapshot: HarnessMonitorNotificationSettingsSnapshot
  let registeredCategoryCount: Int
  let pendingRequestCount: Int
  let deliveredNotificationCount: Int
  let lastResult: String

  @MainActor
  init(notifications: HarnessMonitorUserNotificationController) {
    settingsSnapshot = notifications.settingsSnapshot
    registeredCategoryCount = notifications.registeredCategoryCount
    pendingRequestCount = notifications.pendingRequestCount
    deliveredNotificationCount = notifications.deliveredNotificationCount
    lastResult = notifications.lastResult
  }
}

struct NotificationsStatusSection: View {
  let snapshot: SettingsNotificationsSnapshot

  var body: some View {
    Section {
      LabeledContent("Authorization", value: snapshot.settingsSnapshot.authorizationStatus)
      LabeledContent("Alerts", value: snapshot.settingsSnapshot.alertSetting)
      LabeledContent("Sound", value: snapshot.settingsSnapshot.soundSetting)
      LabeledContent("Badges", value: snapshot.settingsSnapshot.badgeSetting)
      LabeledContent(
        "Notification Center",
        value: snapshot.settingsSnapshot.notificationCenterSetting
      )
      LabeledContent("Lock Screen", value: snapshot.settingsSnapshot.lockScreenSetting)
      LabeledContent("Alert Style", value: snapshot.settingsSnapshot.alertStyle)
      LabeledContent("Previews", value: snapshot.settingsSnapshot.showPreviews)
      LabeledContent("Time Sensitive", value: snapshot.settingsSnapshot.timeSensitiveSetting)
      LabeledContent("Categories", value: "\(snapshot.registeredCategoryCount)")
      LabeledContent("Pending", value: "\(snapshot.pendingRequestCount)")
      LabeledContent("Delivered", value: "\(snapshot.deliveredNotificationCount)")
      LabeledContent("Last Result", value: snapshot.lastResult)
        .textSelection(.enabled)
    } header: {
      Text("System Status")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text("These values come from the system notification center for this app")
        .harnessNativeFormSectionFooter()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsNotificationsStatus)
  }
}
