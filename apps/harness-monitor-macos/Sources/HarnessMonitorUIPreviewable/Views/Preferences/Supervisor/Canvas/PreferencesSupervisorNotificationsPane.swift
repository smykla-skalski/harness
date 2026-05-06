import HarnessMonitorKit
import SwiftUI

public struct PreferencesSupervisorNotificationsPane: View {
  let notifications: HarnessMonitorUserNotificationController
  @State private var viewModel: PreferencesSupervisorNotificationsViewModel
  @Environment(\.openURL)
  private var openURL

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
      acpCatalogSection
      acpStatusSection
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
    .overlay {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.preferencesAcpNotificationStatusState,
        text:
          "authorization=\(acpAuthorizationStatus.rawValue) feature-acp=\(viewModel.acpCatalogEnabled)"
      )
    }
  }

  private var acpAuthorizationStatus: AcpPermissionNotificationAuthorizationStatus {
    AcpPermissionUserNotifications.authorizationStatus(
      from: notifications.settingsSnapshot
    )
  }

  @ViewBuilder private var acpCatalogSection: some View {
    Section {
      Toggle(
        "Enable ACP catalog",
        isOn: Binding(
          get: { viewModel.acpCatalogEnabled },
          set: { enabled in
            let shouldRequestAuthorization =
              enabled
              && !viewModel.acpCatalogEnabled
              && acpAuthorizationStatus == .notDetermined
            viewModel.setAcpCatalogEnabled(enabled)
            guard shouldRequestAuthorization else {
              return
            }
            Task {
              await notifications.requestAuthorization(profile: .standard)
              await notifications.refreshStatus()
            }
          }
        )
      )
      .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesAcpCatalogToggle)
      .disabled(viewModel.acpCatalogForcedByEnvironment)

      LabeledContent("Notification permission", value: acpAuthorizationStatus.displayTitle)
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesAcpCatalogPermission)
      if viewModel.acpCatalogForcedByEnvironment {
        Text("Managed by HARNESS_FEATURE_ACP environment value.")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    } header: {
      Text("ACP Catalog")
    } footer: {
      Text("When enabled, ACP catalog surfaces can request Notification Center permission.")
    }
  }

  @ViewBuilder private var acpStatusSection: some View {
    let verboseAnnouncementHelp = """
      When off, VoiceOver announces only completed or failed tool calls. \
      Turn this on to announce every tool-call state change.
      """
    Section {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        LabeledContent("Background ACP alerts", value: acpAuthorizationStatus.displayTitle)
        Text(acpAuthorizationStatus.detailText)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Toggle(
          "Verbose tool-call announcements",
          isOn: Binding(
            get: { viewModel.verboseToolCallAnnouncementsEnabled },
            set: { viewModel.setVerboseToolCallAnnouncementsEnabled($0) }
          )
        )
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.preferencesAcpVerboseAnnounceToggle
        )
        .accessibilityHint(verboseAnnouncementHelp)
        .help(verboseAnnouncementHelp)
        Text(
          verboseAnnouncementHelp
        )
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        if acpAuthorizationStatus.showsSystemSettingsLink,
          let settingsURL = AcpPermissionUserNotifications.systemSettingsURL
        {
          HarnessMonitorActionButton(
            title: "Open System Settings",
            tint: .secondary,
            variant: .bordered,
            accessibilityIdentifier: HarnessMonitorAccessibility.preferencesAcpOpenSystemSettings
          ) {
            openURL(settingsURL)
          }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesAcpNotificationStatus)
    } header: {
      Text("ACP Attention")
    } footer: {
      Text(
        """
        Notification Center delivery is optional. Dock, badge, and Decisions routes stay available \
        when system permission is denied, and the tool-call announcement toggle only changes \
        VoiceOver verbosity.
        """
      )
    }
  }
}

#Preview("Supervisor Notifications Pane") {
  PreferencesSupervisorNotificationsPane(
    notifications: HarnessMonitorUserNotificationController.preview()
  )
  .frame(width: 600, height: 640)
}
