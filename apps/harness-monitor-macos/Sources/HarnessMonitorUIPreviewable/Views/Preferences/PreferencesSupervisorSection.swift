import HarnessMonitorKit
import SwiftUI

/// Key identifying which Supervisor preferences pane is currently selected. Phase 2 workers
/// 22 and 23 own their respective subviews and wire them via this enum switch. Phase 1 ships
/// the switch so later workers only touch their own subview files.
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

/// Root Supervisor section in the Preferences window. Phase 1 renders a segmented control that
/// switches between three empty pane stubs; Phase 2 worker 22 replaces the `.rules` pane body
/// and worker 23 replaces `.notifications` + `.background`.
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
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        Picker("Pane", selection: $selectedPane) {
          ForEach(SupervisorPaneKey.allCases) { pane in
            Text(pane.title).tag(pane)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.preferencesSupervisorPane("pane-picker")
        )

        Group {
          switch selectedPane {
          case .rules:
            PreferencesSupervisorRulesPane()
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      .padding()
      .navigationTitle("Supervisor")
    }
  }
}

#Preview("Preferences Supervisor Section — empty") {
  PreferencesSupervisorSection(
    store: PreferencesPreviewSupport.makeStore(),
    notifications: HarnessMonitorUserNotificationController.preview()
  )
  .frame(width: 640, height: 480)
}
