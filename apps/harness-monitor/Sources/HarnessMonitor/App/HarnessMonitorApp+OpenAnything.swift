import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI
import os

extension HarnessMonitorApp {
  func presentOpenAnythingPalette() {
    presentOpenAnythingPaletteScoped(to: nil)
  }

  /// Cmd+Shift+K opens the palette with only one domain visible so the
  /// session-only quick switcher never collides with action or settings
  /// results. Plumbing the scope through `present(targetWindowID:scope:)` lets
  /// the model carry the constraint until the next dismiss.
  func presentOpenAnythingPaletteSessions() {
    presentOpenAnythingPaletteScoped(to: .sessions)
  }

  func presentOpenAnythingPaletteScoped(to scope: OpenAnythingDomain?) {
    let controller = appOpenAnythingPaletteController
    // If the palette is already presented, Cmd+K is a toggle-off. Bail
    // immediately - recomputing window state and surfacing dashboard from
    // here resigns the panel's main status and the resignMain callback
    // races the toggle into a re-show.
    if controller.model.isPresented {
      controller.hide()
      return
    }
    // Resolve the active window ID once - the previous implementation called
    // `openAnythingTargetWindowID()` three times per keystroke, each one
    // walking NSApp.windows. That overhead added up on the hot path.
    let activeWindowID = openAnythingTargetWindowID()
    applyOpenAnythingPreferences()
    prepareOpenAnythingLoadedSessionOverride(
      sessionID: openAnythingSessionID(forWindowID: activeWindowID)
    )
    let resolvedScope = scope ?? scopeDerivedFromWindowID(activeWindowID)
    let resolvedContextDomain = contextDomainForActiveView(activeWindowID)
    let restore = UserDefaults.standard.bool(
      forKey: OpenAnythingPreferencesDefaults.restoreLastQueryKey
    )
    // Surface dashboard only if no Monitor scene is key AND the palette
    // panel is not itself key. After an alpha-hide cycle the panel stays
    // ordered front + key, but `openAnythingTargetWindowID()` does not
    // match it; calling `openHarnessDashboardWindow` in that state opens
    // dashboard for no user-visible reason and slows the show pipeline.
    if activeWindowID == nil && !controller.isPanelKey {
      openWindow.openHarnessDashboardWindow()
      focusDashboardWindowIfPossible()
    }
    controller.toggle(
      scope: resolvedScope,
      contextDomain: resolvedContextDomain,
      restoreLastQuery: restore
    )
  }

}

extension HarnessMonitorApp {
  func installAppSceneServicesIfNeeded() {
    guard rendersMenuBarExtraContent else { return }
    guard !hasInstalledAppSceneServicesFlag else { return }
    hasInstalledAppSceneServicesFlag = true
    openAnythingExecutorBinder.bind(openWindow: openWindow)
    syncOpenAnythingGlobalHotKey()
    restartOpenAnythingCorpusDriver(
      loadedSessionOverride: appOpenAnythingLoadedSessionOverride
    )
    appClipboardAutomationPolicyService.start(openWindow: openWindow)
  }

  func syncOpenAnythingGlobalHotKey() {
    guard hasInstalledAppSceneServicesFlag else { return }
    appGlobalHotKeyController.configure(
      enabled: globalOpenAnythingHotKeyEnabled,
      descriptor: OpenAnythingHotKeyDescriptor.decode(globalOpenAnythingHotKeyDescriptor),
      onInvoke: { presentOpenAnythingPalette() }
    )
  }

  func restartOpenAnythingCorpusDriver(
    loadedSessionOverride: OpenAnythingLoadedSessionSnapshot?
  ) {
    guard hasInstalledAppSceneServicesFlag else { return }
    appOpenAnythingCorpusDriver.start(coordinator: appOpenAnythingCoordinator) {
      makeOpenAnythingCorpusInput(loadedSessionOverride: loadedSessionOverride)
    }
  }

  private func makeOpenAnythingCorpusInput(
    loadedSessionOverride: OpenAnythingLoadedSessionSnapshot?
  ) -> OpenAnythingCorpusInput {
    OpenAnythingCorpusInput(
      settingsSections: OpenAnythingAppServiceSettings.settingsSectionProjections,
      sessions: appStore.sessions,
      taskBoardItems: appStore.globalTaskBoardItems,
      decisions: appStore.supervisorOpenDecisionPresentationItems,
      reviews: appOpenAnythingReviews.loadedItems,
      loadedSession: loadedSessionSnapshot(override: loadedSessionOverride)
    )
  }

  private func loadedSessionSnapshot(
    override loadedSessionOverride: OpenAnythingLoadedSessionSnapshot?
  ) -> OpenAnythingLoadedSessionSnapshot? {
    if let loadedSessionOverride {
      return loadedSessionOverride
    }
    guard let sessionID = appStore.selectedSessionID else { return nil }
    return OpenAnythingLoadedSessionSnapshot(
      sessionID: sessionID,
      agents: appStore.selectedSessionAgents,
      tasks: appStore.selectedSessionTasks,
      timeline: appStore.timeline
    )
  }
}

private enum OpenAnythingAppServiceSettings {
  static let settingsSectionProjections = SettingsSection.allCases.map {
    OpenAnythingSettingsSectionProjection(
      rawValue: $0.rawValue,
      title: $0.title,
      systemImage: $0.systemImage
    )
  }
}

/// Binds the Open Anything route executor to the floating-panel controller
/// the first time it mounts. The palette itself lives in an NSPanel that
/// floats above whichever Monitor window is key (see
/// `OpenAnythingPaletteWindowController`), so this modifier no longer renders
/// an overlay - it only carries the SwiftUI environment values (`openWindow`,
/// store bindings) needed to build the execute closure and hands them off to
/// the controller once.
struct HarnessMonitorOpenAnythingExecutorBinder: ViewModifier {
  let controller: OpenAnythingPaletteWindowController
  let reviewRegistry: OpenAnythingDashboardReviewRegistry
  let store: HarnessMonitorStore
  let windowNavigationHistory: GlobalWindowNavigationHistory
  let refreshStore: () -> Void
  @Binding var settingsSelectedSection: SettingsSection
  @Binding var settingsNavigationRequest: SettingsNavigationRequest?
  @Binding var hasBound: Bool
  @Environment(\.openWindow)
  private var openWindow

  func body(content: Content) -> some View {
    content
      .task {
        bind(openWindow: openWindow)
      }
  }

  @MainActor
  func bind(openWindow: OpenWindowAction) {
    guard !hasBound else { return }
    hasBound = true
    controller.bindExecutor(
      { hit in execute(hit, openWindow: openWindow) },
      reviewPinToggle: { pullRequestID in
        toggleReviewPin(pullRequestID: pullRequestID) { message in
          store.presentSuccessFeedback(message)
        }
      }
    )
  }

  private func execute(_ hit: OpenAnythingHit, openWindow: OpenWindowAction) {
    let signpost = OpenAnythingSignposter.shared.beginInterval(
      OpenAnythingSignposter.Interval.execute
    )
    defer {
      OpenAnythingSignposter.shared.endInterval(
        OpenAnythingSignposter.Interval.execute,
        signpost
      )
    }
    // Keep the executor surface as a single entry point keyed on
    // `OpenAnythingTarget`.
    for step in OpenAnythingRouteExecutor.steps(for: hit.target) {
      executeRoutingStep(step, openWindow: openWindow)
    }
  }

  private func executeRoutingStep(_ step: OpenAnythingRoutingStep, openWindow: OpenWindowAction) {
    guard !executePresentationStep(step) else { return }
    guard !executeCommandStep(step) else { return }
    switch step {
    case .openWindow(let target):
      openWindowTarget(target, openWindow: openWindow)
    case .openDashboard(let route):
      openDashboard(route, openWindow: openWindow)
    case .openSettings(let rawValue):
      openSettings(rawValue: rawValue, openWindow: openWindow)
    case .openSessionWindow(let sessionID):
      openWindow.openHarnessSessionWindow(sessionID: sessionID)
    case .requestSessionRoute(let target):
      requestSessionRoute(target)
    case .selectSupervisorDecision(let id):
      store.supervisorSelectedDecisionID = id
    case .selectDashboardReview(let pullRequestID):
      reviewRegistry.requestSelection(pullRequestID: pullRequestID)
    case .presentNewSessionSheet, .presentNewTaskSheet, .attachExternalSession, .refresh,
      .refreshDiagnostics, .reconnectDaemon, .copyDiagnostics, .openExternalURL,
      .revealInFinder:
      break
    }
  }

  private func executeCommandStep(_ step: OpenAnythingRoutingStep) -> Bool {
    switch step {
    case .refreshDiagnostics:
      Task { await store.refreshDiagnostics() }
    case .reconnectDaemon:
      Task { await store.reconnect() }
    case .copyDiagnostics:
      copyMonitorDiagnostics()
    // No current target emits these deep-link steps; they are hooks for row
    // context-menu actions in the palette view. Treated as command-type steps
    // so the routing switch below stays a navigation-only fallback.
    case .openExternalURL(let url):
      NSWorkspace.shared.open(url)
    case .revealInFinder(let url):
      NSWorkspace.shared.activateFileViewerSelecting([url])
    default:
      return false
    }
    return true
  }

  private func executePresentationStep(_ step: OpenAnythingRoutingStep) -> Bool {
    switch step {
    case .presentNewSessionSheet:
      store.presentedSheet = .newSession
    case .presentNewTaskSheet:
      store.requestCreateTaskSheet()
    case .attachExternalSession:
      store.requestAttachExternalSession()
    case .refresh:
      refreshStore()
    default:
      return false
    }
    return true
  }

  private func openWindowTarget(_ target: OpenAnythingWindowTarget, openWindow: OpenWindowAction) {
    switch target {
    case .dashboard:
      openWindow.openHarnessDashboardWindow()
    case .settings:
      openWindow(id: HarnessMonitorWindowID.settings)
    }
  }

  private func openDashboard(_ route: OpenAnythingDashboardRoute, openWindow: OpenWindowAction) {
    let dashboardRoute = DashboardWindowRoute.restoredRoute(rawValue: route.rawValue) ?? .taskBoard
    windowNavigationHistory.requestDashboardRoute(dashboardRoute)
    openWindow.openHarnessDashboardWindow()
  }

  private func copyMonitorDiagnostics() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(monitorDiagnosticsClipboardText(), forType: .string)
    store.presentSuccessFeedback("Diagnostics copied")
  }

  private func monitorDiagnosticsClipboardText() -> String {
    let metrics = store.connectionMetrics
    let diagnostics = store.diagnostics?.workspace ?? store.daemonStatus?.diagnostics
    let health = store.health
    let mcp = store.mcpStatus
    return [
      "Harness Monitor diagnostics",
      "Connection: \(connectionTitle(store.connectionState))",
      "Transport: \(metrics.transportKind.title)",
      "Last request latency: \(optionalMilliseconds(metrics.requestLatencyMs))",
      "Average request latency: \(optionalMilliseconds(metrics.averageRequestLatencyMs))",
      "Daemon version: \(health?.version ?? "unknown")",
      "Daemon pid: \(health.map { String($0.pid) } ?? "unknown")",
      "Daemon endpoint: \(health?.endpoint ?? "unknown")",
      "Manifest: \(diagnostics?.manifestPath ?? "unavailable")",
      "Database: \(diagnostics?.databasePath ?? "unavailable")",
      "Events: \(diagnostics?.eventsPath ?? "unavailable")",
      "Sessions: \(store.sessions.count)",
      "Selected session: \(store.selectedSessionID ?? "none")",
      "Timeline rows: \(store.timeline.count)",
      "MCP: \(mcp.title)",
      "MCP socket: \(mcp.socketPath ?? "unavailable")",
    ]
    .joined(separator: "\n")
  }

  private func connectionTitle(_ state: HarnessMonitorStore.ConnectionState) -> String {
    switch state {
    case .idle:
      "Idle"
    case .connecting:
      "Connecting"
    case .online:
      "Online"
    case .offline(let reason):
      "Offline: \(reason)"
    }
  }

  private func optionalMilliseconds(_ value: Int?) -> String {
    guard let value else { return "n/a" }
    return "\(value) ms"
  }

  private func openSettings(rawValue: String, openWindow: OpenWindowAction) {
    guard let section = SettingsSection(rawValue: rawValue) else {
      openWindow(id: HarnessMonitorWindowID.settings)
      return
    }
    settingsSelectedSection = section
    settingsNavigationRequest = SettingsNavigationRequest(target: .section(section))
    openWindow(id: HarnessMonitorWindowID.settings)
  }

  private func requestSessionRoute(_ target: OpenAnythingSessionRouteTarget) {
    switch target {
    case .agent(let sessionID, let agentID):
      store.requestSessionRoute(.agent(sessionID: sessionID, agentID: agentID))
    case .task(let sessionID, let taskID):
      store.requestSessionRoute(.task(sessionID: sessionID, taskID: taskID))
    case .decision(let sessionID, let decisionID, let resetDecisionFilters):
      store.requestSessionRoute(
        .decision(sessionID: sessionID, decisionID: decisionID),
        resetDecisionFilters: resetDecisionFilters
      )
    case .timeline(let sessionID, let entryID):
      store.requestSessionRoute(.timeline(sessionID: sessionID, entryID: entryID))
    }
  }
}
