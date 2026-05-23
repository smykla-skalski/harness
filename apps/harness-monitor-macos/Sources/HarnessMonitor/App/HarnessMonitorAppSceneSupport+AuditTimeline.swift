import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

/// Wires the Supervisor audit-timeline cross-link surfaces into the dashboard
/// scene: an environment action consumed by the per-decision audit-trail tab,
/// and a focused-scene value consumed by the View > Audit Timeline command.
/// Both paths route to Settings > Supervisor > Audit and stash the query
/// payload on the focus dispatcher so the Audit pane can pre-apply filters
/// the moment it mounts.
struct SupervisorAuditTimelineSceneModifier: ViewModifier {
  @Binding var settingsSelectedSection: SettingsSection
  @Binding var settingsNavigationRequest: SettingsNavigationRequest?
  let dispatcher: SupervisorAuditTimelineFocusDispatcher
  @Environment(\.openWindow)
  private var openWindow

  func body(content: Content) -> some View {
    content
      .environment(\.openSupervisorAuditTimeline, openAuditTimelineEnvAction)
      .environment(\.supervisorAuditTimelineDispatcher, dispatcher)
      .harnessFocusedSceneValue(
        \.supervisorAuditTimelineFocus,
        SupervisorAuditTimelineFocus(dispatcher: dispatcher)
      )
      .task {
        dispatcher.navigationHandler = { _ in
          openAuditPaneNavigation()
        }
      }
  }

  /// Routes both menu commands (`Cmd+Shift+A`) and per-decision cross-links
  /// through the dispatcher so the navigation and filter-forwarding paths
  /// converge on one entry point.
  private var openAuditTimelineEnvAction: OpenSupervisorAuditTimelineAction {
    OpenSupervisorAuditTimelineAction { query in
      dispatcher.invoke(query: query)
    }
  }

  private func openAuditPaneNavigation() {
    settingsSelectedSection = .supervisor
    settingsNavigationRequest = SettingsNavigationRequest(target: .supervisor(.audit))
    openWindow(id: HarnessMonitorWindowID.settings)
  }
}
