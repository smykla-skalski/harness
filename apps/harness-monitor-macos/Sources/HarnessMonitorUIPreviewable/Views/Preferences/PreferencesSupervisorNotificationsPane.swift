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

private struct SupervisorSeveritySection: View {
  let severity: DecisionSeverity
  @Bindable var viewModel: PreferencesSupervisorNotificationsViewModel

  var body: some View {
    Section {
      LabeledContent {
        Toggle(
          "",
          isOn: Binding(
            get: { viewModel.allowsAny(for: severity) },
            set: { viewModel.setAllowed($0, for: severity) }
          )
        )
        .labelsHidden()
        .accessibilityIdentifier(
          "supervisor-notifications-master-\(severity.rawValue)"
        )
      } label: {
        HStack(spacing: 12) {
          SeverityIconBadge(severity: severity)
          VStack(alignment: .leading, spacing: 2) {
            Text("Allow notifications")
              .font(.body)
            Text(severity.preferencesTitle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .accessibilityElement(children: .contain)

      if viewModel.allowsAny(for: severity) {
        ForEach(SupervisorNotificationChannel.allCases) { channel in
          channelToggle(channel)
        }
      }
    } footer: {
      Text(viewModel.enabledChannelsDescription(for: severity))
    }
  }

  @ViewBuilder
  private func channelToggle(_ channel: SupervisorNotificationChannel) -> some View {
    Toggle(
      channel.title,
      isOn: Binding(
        get: { viewModel.isEnabled(channel, for: severity) },
        set: { viewModel.setEnabled($0, channel: channel, for: severity) }
      )
    )
    .accessibilityIdentifier(
      "supervisor-notifications-channel-\(severity.rawValue)-\(channel.rawValue)"
    )
  }
}

private struct SeverityIconBadge: View {
  let severity: DecisionSeverity

  var body: some View {
    Image(systemName: severity.iconName)
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 28, height: 28)
      .background(severity.tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .accessibilityHidden(true)
  }
}

#Preview("Supervisor Notifications Pane") {
  PreferencesSupervisorNotificationsPane(
    notifications: HarnessMonitorUserNotificationController.preview()
  )
  .frame(width: 600, height: 640)
}

extension DecisionSeverity {
  fileprivate var preferencesTitle: String {
    switch self {
    case .info: "Info decisions"
    case .warn: "Warning decisions"
    case .needsUser: "Needs-user decisions"
    case .critical: "Critical decisions"
    }
  }

  fileprivate var iconName: String {
    switch self {
    case .info: "info.circle.fill"
    case .warn: "exclamationmark.triangle.fill"
    case .needsUser: "person.fill.questionmark"
    case .critical: "exclamationmark.octagon.fill"
    }
  }

  fileprivate var tint: Color {
    switch self {
    case .info: .blue
    case .warn: .yellow
    case .needsUser: .orange
    case .critical: .red
    }
  }
}
