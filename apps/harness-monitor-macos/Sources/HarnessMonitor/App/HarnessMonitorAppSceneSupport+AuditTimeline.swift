import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

/// Wires the Supervisor audit-timeline cross-link surfaces into the dashboard
/// scene: an environment action consumed by the per-decision audit-trail tab,
/// and a focused-scene value consumed by the View > Audit Timeline command.
/// Both paths route to Settings > Supervisor > Audit.
struct SupervisorAuditTimelineSceneModifier: ViewModifier {
  @Binding var settingsSelectedSection: SettingsSection
  @Binding var settingsNavigationRequest: SettingsNavigationRequest?
  @Environment(\.openWindow)
  private var openWindow
  @State private var dispatcher = SupervisorAuditTimelineFocusDispatcher()

  func body(content: Content) -> some View {
    let action = openAuditTimelineEnvAction
    content
      .environment(\.openSupervisorAuditTimeline, action)
      .focusedSceneValue(
        \.supervisorAuditTimelineFocus,
        SupervisorAuditTimelineFocus(dispatcher: dispatcher)
      )
      .task {
        dispatcher.handler = { query in
          action(query)
        }
      }
  }

  private var openAuditTimelineEnvAction: OpenSupervisorAuditTimelineAction {
    OpenSupervisorAuditTimelineAction { _ in
      // Filter forwarding to the audit pane store is wired by sibling units
      // once that store lands. The route itself is enough to make the menu
      // and decision-tab cross-link reach the right pane today.
      settingsSelectedSection = .supervisor
      settingsNavigationRequest = SettingsNavigationRequest(target: .supervisor(.audit))
      openWindow(id: HarnessMonitorWindowID.settings)
    }
  }
}
