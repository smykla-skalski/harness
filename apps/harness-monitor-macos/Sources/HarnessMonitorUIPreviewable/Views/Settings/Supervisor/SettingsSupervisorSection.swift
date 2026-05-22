import HarnessMonitorKit
import SwiftUI

/// Key identifying which Supervisor settings pane is currently selected.
public enum SupervisorPaneKey: String, CaseIterable, Hashable, Identifiable, Sendable {
  case rules
  case notifications
  case background
  case audit

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .rules: "Rules"
    case .notifications: "Notifications"
    case .background: "Background"
    case .audit: "Audit"
    }
  }

  /// Panes that the toolbar segmented picker should surface today. The `.audit`
  /// pane is reachable via the cross-link and command shortcut but stays out of
  /// the live picker until its full content ships from sibling units.
  public static let toolbarVisibleCases: [SupervisorPaneKey] = [
    .rules, .notifications, .background,
  ]
}

/// Root Supervisor section in the Settings window. The pane switcher lives in the window
/// toolbar, while each pane owns its own `Form` and `settingsDetailFormStyle()`.
public struct SettingsSupervisorSection: View {
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  @Binding var selectedPane: SupervisorPaneKey

  public init(
    store: HarnessMonitorStore,
    notifications: HarnessMonitorUserNotificationController,
    selectedPane: Binding<SupervisorPaneKey>
  ) {
    self.store = store
    self.notifications = notifications
    _selectedPane = selectedPane
  }

  public var body: some View {
    Group {
      switch selectedPane {
      case .rules:
        SettingsSupervisorRulesPane(store: store)
      case .notifications:
        SettingsSupervisorNotificationsPane(notifications: notifications)
      case .background:
        SettingsSupervisorBackgroundPane(
          onRunInBackgroundChange: { enabled in
            store.setSupervisorRunInBackgroundEnabled(enabled)
          },
          onQuietHoursChange: { window, _ in
            store.setSupervisorQuietHoursWindow(window)
          }
        )
      case .audit:
        SettingsSupervisorAuditPane()
      }
    }
  }
}

private enum SupervisorPaneToolbarMetrics {
  static let width: CGFloat = 380
}

struct SupervisorSettingsToolbarPicker: View {
  @Binding var selection: SupervisorPaneKey

  var body: some View {
    Picker("Pane", selection: $selection) {
      ForEach(SupervisorPaneKey.toolbarVisibleCases) { pane in
        Text(pane.title)
          .tag(pane)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.segmentedOption(
              HarnessMonitorAccessibility.settingsSupervisorPane("pane-picker"),
              option: pane.title
            )
          )
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .controlSize(.large)
    .frame(width: SupervisorPaneToolbarMetrics.width)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.settingsSupervisorPane("pane-picker")
    )
  }
}
