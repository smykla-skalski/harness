import HarnessMonitorKit
import SwiftUI

/// Key identifying which Supervisor preferences pane is currently selected.
public enum SupervisorPaneKey: String, CaseIterable, Hashable, Identifiable {
  case rules
  case notifications
  case background

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .rules: "Rules"
    case .notifications: "Notifications"
    case .background: "Background"
    }
  }
}

/// Root Supervisor section in the Preferences window. The pane switcher lives in the window
/// toolbar, while each pane owns its own `Form` and `preferencesDetailFormStyle()`.
public struct PreferencesSupervisorSection: View {
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
        PreferencesSupervisorRulesPane(store: store)
      case .notifications:
        PreferencesSupervisorNotificationsPane(notifications: notifications)
      case .background:
        PreferencesSupervisorBackgroundPane(
          onRunInBackgroundChange: { enabled in
            store.setSupervisorRunInBackgroundEnabled(enabled)
          },
          onQuietHoursChange: { window, _ in
            store.setSupervisorQuietHoursWindow(window)
          }
        )
      }
    }
  }
}

private enum SupervisorPaneToolbarMetrics {
  static let width: CGFloat = 380
}

struct SupervisorPreferencesToolbarPicker: View {
  @Binding var selection: SupervisorPaneKey

  var body: some View {
    Picker("Pane", selection: $selection) {
      ForEach(SupervisorPaneKey.allCases) { pane in
        Text(pane.title)
          .tag(pane)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.segmentedOption(
              HarnessMonitorAccessibility.preferencesSupervisorPane("pane-picker"),
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
      HarnessMonitorAccessibility.preferencesSupervisorPane("pane-picker")
    )
  }
}

#Preview("Preferences Supervisor Section — empty") {
  @Previewable @State var selectedPane: SupervisorPaneKey = .rules

  PreferencesSupervisorSection(
    store: PreferencesPreviewSupport.makeStore(),
    notifications: HarnessMonitorUserNotificationController.preview(),
    selectedPane: $selectedPane
  )
  .frame(width: 640, height: 480)
}
