import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct SessionWindowRootView: View {
  private static let minimumSize = CGSize(width: 920, height: 620)

  let token: SessionWindowToken
  let store: HarnessMonitorStore
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

  var body: some View {
    HarnessMonitorWindowShell(
      windowID: windowID,
      windowTitle: windowTitle,
      scope: .session,
      minimumSize: Self.minimumSize,
      accessibilityIdentifier: HarnessMonitorAccessibility.sessionWindowShell,
      keyWindowObserver: keyWindowObserver,
      windowCommandRouting: windowCommandRouting,
      mcpWindowCommandRegistrar: mcpWindowCommandRegistrar,
      themeMode: $themeMode,
      appliesPreferredColorScheme: true
    ) {
      SessionWindowView(store: store, token: token)
    }
    .navigationTitle(windowTitle)
    .modifier(
      SessionWindowLifecycleModifier(
        store: store,
        sessionID: token.sessionID,
        tracker: sessionWindowPresenceTracker
      )
    )
  }
}
