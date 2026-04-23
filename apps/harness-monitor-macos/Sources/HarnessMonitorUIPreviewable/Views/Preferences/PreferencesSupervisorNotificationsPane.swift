import HarnessMonitorKit
import SwiftUI

public struct PreferencesSupervisorNotificationsPane: View {
  let notifications: HarnessMonitorUserNotificationController
  @State private var viewModel: PreferencesSupervisorNotificationsViewModel

  public init(
    notifications: HarnessMonitorUserNotificationController,
    userDefaults: UserDefaults = .standard
  ) {
    self.notifications = notifications
    _viewModel = State(
      initialValue: PreferencesSupervisorNotificationsViewModel(userDefaults: userDefaults)
    )
  }

  public var body: some View {
    Form {
      Section {
        LabeledContent("Authorization", value: notifications.settingsSnapshot.authorizationStatus)
        LabeledContent("Alerts", value: notifications.settingsSnapshot.alertSetting)
        LabeledContent("Sound", value: notifications.settingsSnapshot.soundSetting)
        LabeledContent("Badges", value: notifications.settingsSnapshot.badgeSetting)
        LabeledContent(
          "Notification Center",
          value: notifications.settingsSnapshot.notificationCenterSetting
        )
        LabeledContent("Lock Screen", value: notifications.settingsSnapshot.lockScreenSetting)
      } header: {
        Text("System Status")
      } footer: {
        Text("Per-severity channel toggles apply inside the capabilities the system grants")
      }

      ForEach(DecisionSeverity.allCases, id: \.self) { severity in
        SupervisorSeveritySection(severity: severity, viewModel: viewModel)
      }
    }
    .toggleStyle(.switch)
    .preferencesDetailFormStyle()
    .task { await notifications.refreshStatus() }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.preferencesSupervisorPane("notifications")
    )
  }
}

#Preview("Supervisor Notifications Pane") {
  PreferencesSupervisorNotificationsPane(
    notifications: HarnessMonitorUserNotificationController.preview()
  )
  .frame(width: 600, height: 640)
}
