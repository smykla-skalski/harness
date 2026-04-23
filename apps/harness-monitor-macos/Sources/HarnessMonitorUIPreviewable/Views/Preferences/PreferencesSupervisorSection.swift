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

/// Root Supervisor section in the Preferences window. Renders a native scope bar pinned to the
/// top safe area and delegates to the selected pane. Each pane owns its own `Form` and
/// `preferencesDetailFormStyle()` so the sidebar can continue to supply the detail column title.
public struct PreferencesSupervisorSection: View {
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  @State private var selectedPane: SupervisorPaneKey = .rules

  public init(
    store: HarnessMonitorStore,
    notifications: HarnessMonitorUserNotificationController
  ) {
    self.store = store
    self.notifications = notifications
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
    .safeAreaInset(edge: .top, spacing: 0) {
      SupervisorScopeBar(selection: $selectedPane)
    }
  }
}

private struct SupervisorScopeBar: View {
  @Binding var selection: SupervisorPaneKey

  var body: some View {
    HStack {
      Spacer(minLength: 0)
      Picker("Pane", selection: $selection) {
        ForEach(SupervisorPaneKey.allCases) { pane in
          Text(pane.title).tag(pane)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .controlSize(.large)
      .frame(maxWidth: 380)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.preferencesSupervisorPane("pane-picker")
      )
      Spacer(minLength: 0)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingLG)
    .padding(.top, HarnessMonitorTheme.spacingMD)
    .padding(.bottom, HarnessMonitorTheme.spacingSM)
  }
}

#Preview("Preferences Supervisor Section — empty") {
  PreferencesSupervisorSection(
    store: PreferencesPreviewSupport.makeStore(),
    notifications: HarnessMonitorUserNotificationController.preview()
  )
  .frame(width: 640, height: 480)
}
