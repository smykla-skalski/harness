import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftData
import SwiftUI

struct HarnessMonitorDashboardWindowContent: View {
  let delegate: HarnessMonitorAppDelegate
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  let keyWindowObserver: KeyWindowObserver
  let acpAttentionState: AcpPermissionAttentionState
  let windowCommandRouting: WindowCommandRoutingState
  let windowNavigationHistory: GlobalWindowNavigationHistory
  let mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar
  @Binding var themeMode: HarnessMonitorThemeMode
  @Binding var settingsSelectedSection: SettingsSection
  @Binding var settingsNavigationRequest: SettingsNavigationRequest?
  let supervisorAuditTimelineDispatcher: SupervisorAuditTimelineFocusDispatcher
  let perfScenario: HarnessMonitorPerfScenario?
  @Binding var hasRunPerfScenario: Bool
  @Binding var perfScenarioStatus: HarnessMonitorPerfScenarioStatus
  @Binding var perfScenarioFailureReason: String?
  let defersInitialContentUntilBootstrap: Bool
  let presentOpenAnything: @MainActor @Sendable () -> Void
  let setOpenAnythingQuery: @MainActor @Sendable (String) -> Void
  let container: ModelContainer?

  var body: some View {
    Group {
      if let container {
        windowRoot
          .modelContainer(container)
      } else {
        windowRoot
      }
    }
  }

  private var windowRoot: some View {
    DashboardWindowRootView(
      delegate: delegate,
      store: store,
      notifications: notifications,
      keyWindowObserver: keyWindowObserver,
      acpAttentionState: acpAttentionState,
      windowCommandRouting: windowCommandRouting,
      windowNavigationHistory: windowNavigationHistory,
      mcpWindowCommandRegistrar: mcpWindowCommandRegistrar,
      themeMode: $themeMode,
      settingsSelectedSection: $settingsSelectedSection,
      settingsNavigationRequest: $settingsNavigationRequest,
      supervisorAuditTimelineDispatcher: supervisorAuditTimelineDispatcher,
      perfScenario: perfScenario,
      hasRunPerfScenario: $hasRunPerfScenario,
      perfScenarioStatus: $perfScenarioStatus,
      perfScenarioFailureReason: $perfScenarioFailureReason,
      defersInitialContentUntilBootstrap: defersInitialContentUntilBootstrap,
      presentOpenAnything: presentOpenAnything,
      setOpenAnythingQuery: setOpenAnythingQuery
    )
  }
}
