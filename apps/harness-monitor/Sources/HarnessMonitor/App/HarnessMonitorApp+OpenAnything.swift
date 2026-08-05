import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI
import os

extension HarnessMonitorApp {
  func presentOpenAnythingPalette() {
    presentOpenAnythingPaletteScoped(to: nil)
  }

  func presentOpenAnythingPaletteScoped(to scope: OpenAnythingDomain?) {
    let controller = appOpenAnythingPaletteController
    // If the palette is already presented, Cmd+K is a toggle-off. Bail
    // immediately so the resignKey callback cannot race the toggle into a
    // re-show.
    if controller.model.isPresented {
      controller.hide()
      return
    }
    // Resolve the active window ID once - the previous implementation called
    // `openAnythingTargetWindowID()` three times per keystroke, each one
    // walking NSApp.windows. That overhead added up on the hot path.
    let activeWindowID = openAnythingTargetWindowID()
    applyOpenAnythingPreferences()
    let resolvedScope = scope ?? scopeDerivedFromWindowID(activeWindowID)
    let resolvedContextDomain = contextDomainForActiveView(activeWindowID)
    let restore = UserDefaults.standard.bool(
      forKey: OpenAnythingPreferencesDefaults.restoreLastQueryKey
    )
    controller.toggle(
      targetWindowID: activeWindowID,
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
      loadedSessionOverride: nil
    )
    appAutomationPolicyRuntimeService.start(store: appStore)
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

func openAnythingRequiresDashboardPresentationHost(
  targetWindowID: String?,
  presentationTargetCanHostSharedSheet: Bool
) -> Bool {
  guard let targetWindowID else { return true }
  let isSharedSheetHost =
    targetWindowID == HarnessMonitorWindowID.dashboard
  return !isSharedSheetHost || !presentationTargetCanHostSharedSheet
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
    guard !executePresentationStep(step, openWindow: openWindow) else { return }
    guard !executeCommandStep(step) else { return }
    switch step {
    case .openWindow(let target):
      openWindowTarget(target, openWindow: openWindow)
    case .openDashboard(let route):
      openDashboard(route, openWindow: openWindow)
    case .openDashboardAgent(let target):
      openWindow.openHarnessDashboardAgent(target)
    case .openDashboardTaskBoard(let target):
      openWindow.openHarnessDashboardTaskBoard(target)
    case .openDashboardAudit(let target):
      openWindow.openHarnessDashboardAudit(target)
    case .openSettings(let rawValue):
      openSettings(rawValue: rawValue, openWindow: openWindow)
    case .selectDashboardReview(let pullRequestID):
      reviewRegistry.requestSelection(pullRequestID: pullRequestID)
    case .presentNewSessionSheet, .presentNewTaskSheet, .attachExternalSession, .refresh,
      .refreshDiagnostics, .reconnectDaemon, .copyDiagnostics, .openExternalURL,
      .revealInFinder:
      break
    }
    activateHarnessIfNeeded(for: step)
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

  private func executePresentationStep(
    _ step: OpenAnythingRoutingStep,
    openWindow: OpenWindowAction
  ) -> Bool {
    switch step {
    case .presentNewSessionSheet:
      openDashboardPresentationHostIfNeeded(openWindow: openWindow)
      activateHarnessIfNeeded(for: step)
      store.presentedSheet = .newSession
    case .presentNewTaskSheet:
      openDashboardPresentationHostIfNeeded(openWindow: openWindow)
      activateHarnessIfNeeded(for: step)
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

  private func activateHarnessIfNeeded(for step: OpenAnythingRoutingStep) {
    guard openAnythingRoutingStepRequiresApplicationActivation(step) else { return }
    guard !NSApplication.shared.isActive else { return }
    if #available(macOS 14.0, *) {
      NSApplication.shared.activate()
    } else {
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
  }

  private func openDashboardPresentationHostIfNeeded(openWindow: OpenWindowAction) {
    guard
      openAnythingRequiresDashboardPresentationHost(
        targetWindowID: controller.model.targetWindowID,
        presentationTargetCanHostSharedSheet: controller.presentationTargetCanHostSharedSheet
      )
    else {
      return
    }
    openWindow.openHarnessDashboardWindow()
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

}
