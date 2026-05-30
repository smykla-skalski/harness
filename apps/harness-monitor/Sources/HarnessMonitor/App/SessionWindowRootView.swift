import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct SessionWindowRootView: View {
  private static let minimumSize = CGSize(width: 920, height: 620)

  @Environment(\.openWindow)
  private var openWindow

  let token: SessionWindowToken
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  let acpAttentionState: AcpPermissionAttentionState
  let keyWindowObserver: KeyWindowObserver
  let windowCommandRouting: WindowCommandRoutingState
  let windowNavigationHistory: GlobalWindowNavigationHistory
  let mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar
  let sessionWindowPresenceTracker: SessionWindowPresenceTracker
  let initialRoute: SessionWindowRoute?
  @Binding var themeMode: HarnessMonitorThemeMode
  let perfScenario: HarnessMonitorPerfScenario?
  @Binding var perfScenarioStatus: HarnessMonitorPerfScenarioStatus
  @Binding var perfScenarioFailureReason: String?

  private var windowID: String {
    HarnessMonitorWindowID.sessionWindow(token.sessionID)
  }

  private var windowTitle: String {
    store.sessionIndex.sessionSummary(for: token.sessionID)?.displayTitle ?? "Session"
  }

  private var pendingDecisionCount: Int {
    store.supervisorOpenDecisionIDsBySession[token.sessionID]?.count ?? 0
  }

  private var pendingDecisionSeverity: DecisionSeverity? {
    var seen: Set<DecisionSeverity> = []
    for decision in store.supervisorPresentationItemsBySession[token.sessionID] ?? [] {
      if let severity = DecisionSeverity(rawValue: decision.severityRaw) {
        seen.insert(severity)
      }
    }
    for severity in DecisionSeverity.allCases.reversed() where seen.contains(severity) {
      return severity
    }
    return nil
  }

  private var hostsSharedShellPresentation: Bool {
    keyWindowObserver.isKey(windowID: windowID)
  }

  private var shouldPublishPerfScenarioState: Bool {
    HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled
  }

  private var sessionPerfScenarioStateText: String? {
    resolvedPerfScenarioStateText(
      perfScenario: perfScenario,
      status: perfScenarioStatus,
      failureReason: perfScenarioFailureReason,
      publishesState: shouldPublishPerfScenarioState
    )
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
      windowToolbarBackgroundVisibility: .automatic,
      toast: store.toast
    ) {
      SessionWindowView(
        store: store,
        token: token,
        initialRoute: initialRoute,
        history: windowNavigationHistory
      )
      .environment(
        \.openDashboardRoute,
        OpenDashboardRouteAction { route in
          windowNavigationHistory.requestDashboardRoute(route)
          openWindow(id: HarnessMonitorWindowID.dashboard)
        }
      )
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
    .modifier(SessionWindowAppKitBinding(sessionID: token.sessionID))
    .modifier(
      SessionWindowTabbing(
        role: .session,
        tabTitle: windowTitle,
        pendingDecisionCount: pendingDecisionCount,
        pendingDecisionSeverity: pendingDecisionSeverity
      )
    )
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
    .modifier(PerfScenarioStateMarker(text: sessionPerfScenarioStateText))
  }
}
