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
        Text("Per-severity channel toggles apply inside the capabilities the system grants.")
      }

      ForEach(DecisionSeverity.allCases, id: \.self) { severity in
        Section {
          ForEach(SupervisorNotificationChannel.allCases) { channel in
            Toggle(
              channel.title,
              isOn: Binding(
                get: { viewModel.isEnabled(channel, for: severity) },
                set: { viewModel.setEnabled($0, channel: channel, for: severity) }
              )
            )
          }
        } header: {
          Text(severity.preferencesTitle)
        } footer: {
          Text(viewModel.enabledChannelsDescription(for: severity))
        }
      }
    }
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
  .frame(width: 600, height: 400)
}

extension DecisionSeverity {
  fileprivate var preferencesTitle: String {
    switch self {
    case .info: "Info"
    case .warn: "Warning"
    case .needsUser: "Needs User"
    case .critical: "Critical"
    }
  }
}
