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
  let mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar
  @Binding var themeMode: HarnessMonitorThemeMode
  @Binding var settingsSelectedSection: SettingsSection
  let perfScenario: HarnessMonitorPerfScenario?
  let defersInitialContentUntilBootstrap: Bool
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
      mcpWindowCommandRegistrar: mcpWindowCommandRegistrar,
      themeMode: $themeMode,
      settingsSelectedSection: $settingsSelectedSection,
      perfScenario: perfScenario,
      defersInitialContentUntilBootstrap: defersInitialContentUntilBootstrap
    )
  }
}
