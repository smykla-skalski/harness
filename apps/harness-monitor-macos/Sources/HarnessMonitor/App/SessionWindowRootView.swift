import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct SessionWindowRootView: View {
  private static let minimumSize = CGSize(width: 920, height: 620)

  let token: SessionWindowToken
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  let acpAttentionState: AcpPermissionAttentionState
  let keyWindowObserver: KeyWindowObserver
  let windowCommandRouting: WindowCommandRoutingState
  let mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar
  let sessionWindowPresenceTracker: SessionWindowPresenceTracker
  @Binding var themeMode: HarnessMonitorThemeMode

  private var windowID: String {
    HarnessMonitorWindowID.sessionWindow(token.sessionID)
  }

  private var windowTitle: String {
    store.sessionIndex.sessionSummary(for: token.sessionID)?.displayTitle ?? "Session"
  }

  private var hostsSharedShellPresentation: Bool {
    keyWindowObserver.isKey(windowID: windowID)
  }

  var body: some View {
    HarnessMonitorWindowShell(
      windowID: windowID,
      windowTitle: windowTitle,
      scope: .session,
      sessionID: token.sessionID,
      minimumSize: Self.minimumSize,
      accessibilityIdentifier: HarnessMonitorAccessibility.sessionWindowShell,
      keyWindowObserver: keyWindowObserver,
      windowCommandRouting: windowCommandRouting,
      mcpWindowCommandRegistrar: mcpWindowCommandRegistrar,
      themeMode: $themeMode,
      appliesPreferredColorScheme: true,
      toast: store.toast
    ) {
      SessionWindowView(store: store, token: token)
    }
    .suppressToolbarBaselineSeparator(
      markedAs: HarnessMonitorAccessibility.sessionWindowToolbarSeparatorSuppressed
    )
    .modifier(
      SessionWindowLifecycleModifier(
        store: store,
        sessionID: token.sessionID,
        tracker: sessionWindowPresenceTracker
      )
    )
    .modifier(SessionWindowTabbing(isSessionWindow: true))
    .modifier(
      HarnessMonitorConfirmationDialogModifier(
        store: store,
        shellUI: store.contentUI.shell,
        isEnabled: hostsSharedShellPresentation
      )
    )
    .modifier(
      HarnessMonitorSheetModifier(
        store: store,
        shellUI: store.contentUI.shell,
        isEnabled: hostsSharedShellPresentation
      )
    )
    .acpPermissionAttentionScene(
      store: store,
      notifications: notifications,
      attentionState: acpAttentionState,
      windowID: windowID
    )
  }
}
