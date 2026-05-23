import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

extension HarnessMonitorApp {
  func presentOpenAnythingPalette() {
    presentOpenAnythingPaletteScoped(to: nil)
  }

  /// Audit #78: Cmd+Shift+K opens the palette with only one domain visible so
  /// the session-only quick switcher never collides with action / settings
  /// results. Plumbing the scope through `present(targetWindowID:scope:)` lets
  /// the model carry the constraint until the next dismiss.
  func presentOpenAnythingPaletteSessions() {
    presentOpenAnythingPaletteScoped(to: .sessions)
  }

  func presentOpenAnythingPaletteScoped(to scope: OpenAnythingDomain?) {
    keyWindowObserver.refresh()
    let resolvedWindowID = openAnythingTargetWindowID()
    applyOpenAnythingPreferences()
    let resolvedScope = scope ?? scopeDerivedFromWindowID(resolvedWindowID)
    let restore = UserDefaults.standard.bool(
      forKey: OpenAnythingPreferencesDefaults.restoreLastQueryKey
    )
    if let windowID = resolvedWindowID {
      appOpenAnythingPalette.present(
        targetWindowID: windowID,
        scope: resolvedScope,
        restoreLastQuery: restore
      )
      return
    }
    openWindow.openHarnessDashboardWindow()
    focusDashboardWindowIfPossible()
    appOpenAnythingPalette.present(
      targetWindowID: HarnessMonitorWindowID.dashboard,
      scope: resolvedScope,
      restoreLastQuery: restore
    )
  }

  /// Audit #89: push the user's per-section cap into the palette model just
  /// before presenting so the next search and the suggested lane both honor
  /// the live Settings value without a relaunch.
  private func applyOpenAnythingPreferences() {
    let defaults = UserDefaults.standard
    let storedLimit = defaults.object(
      forKey: OpenAnythingPreferencesDefaults.perDomainLimitKey
    ) as? Int ?? OpenAnythingPreferencesDefaults.perDomainLimitDefault
    let clamped = max(
      OpenAnythingPreferencesDefaults.perDomainLimitMin,
      min(OpenAnythingPreferencesDefaults.perDomainLimitMax, storedLimit)
    )
    appOpenAnythingPalette.limitPerDomain = clamped
  }

  /// Audit #79: when the "Scope to current window" toggle is on, derive a
  /// scope from the window the palette opens against - session windows get
  /// loadedSession, the settings window narrows to settings, dashboard / lab
  /// surfaces stay unscoped because they are intentionally cross-cutting.
  private func scopeDerivedFromWindowID(_ windowID: String?) -> OpenAnythingDomain? {
    guard
      UserDefaults.standard.bool(
        forKey: OpenAnythingPreferencesDefaults.scopeToWindowKey
      )
    else { return nil }
    guard let windowID else { return nil }
    if windowID == HarnessMonitorWindowID.settings {
      return .settings
    }
    if windowID.hasPrefix("session-") {
      return .loadedSession
    }
    return nil
  }

  // Use `KeyWindowObserver.isKey(windowID:)` for every candidate so the
  // matcher stays consistent with the same observer used to gate the overlay
  // visibility in the host modifier. The old exact-equality fallback drifted
  // from `isKey`'s tokenised matcher and could fail silently when AppKit
  // decorated the key window's identifier.
  private func openAnythingTargetWindowID() -> String? {
    let observer = keyWindowObserver
    if observer.isKey(windowID: HarnessMonitorWindowID.dashboard) {
      return HarnessMonitorWindowID.dashboard
    }
    if observer.isKey(windowID: HarnessMonitorWindowID.settings) {
      return HarnessMonitorWindowID.settings
    }
    if observer.isKey(windowID: HarnessMonitorWindowID.policyCanvasLab) {
      return HarnessMonitorWindowID.policyCanvasLab
    }
    if let identifier = observer.snapshot.keyWindowIdentifier,
      identifier.hasPrefix("session-")
    {
      return identifier
    }
    return nil
  }

  private func focusDashboardWindowIfPossible() {
    if #available(macOS 14.0, *) {
      NSApplication.shared.activate()
    } else {
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
    DashboardWindowAppKitRegistry.shared.window?.makeKeyAndOrderFront(nil)
  }
}

/// Single-mount engine driver for the Open Anything palette.
///
/// Previously, every window's host modifier carried its own corpus-rebuild
/// task plus its own Carbon hot-key registration call. With N session windows
/// open, every store change triggered N redundant hashes (200-entry timeline
/// included) and N redundant `RegisterEventHotKey` cycles. Mounting this
/// driver exactly once in the dashboard scene centralises both responsibilities
/// behind a deterministic content signature.
struct OpenAnythingEngineHost: View {
  let coordinator: OpenAnythingCorpusCoordinator
  let store: HarnessMonitorStore
  let reviewRegistry: OpenAnythingDashboardReviewRegistry
  let showsPolicyCanvasLab: Bool
  let globalHotKeyController: GlobalHotKeyController
  let globalHotKeyEnabled: Bool
  let globalHotKeyDescriptorStorage: String
  let presentPalette: @MainActor @Sendable () -> Void

  var body: some View {
    let records = makeRecords()
    let signature = OpenAnythingCorpusSignature.compute(records)
    return Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .task(id: signature) {
        await coordinator.acceptCorpus(records, signature: signature)
      }
      .task(id: hotKeySignature) {
        globalHotKeyController.configure(
          enabled: globalHotKeyEnabled,
          descriptor: OpenAnythingHotKeyDescriptor.decode(globalHotKeyDescriptorStorage),
          onInvoke: presentPalette
        )
      }
  }

  private var hotKeySignature: String {
    "\(globalHotKeyEnabled)-\(globalHotKeyDescriptorStorage)"
  }

  private func makeRecords() -> [OpenAnythingRecord] {
    OpenAnythingCorpusBuilder.records(
      input: OpenAnythingCorpusInput(
        settingsSections: SettingsSection.allCases.map {
          OpenAnythingSettingsSectionProjection(
            rawValue: $0.rawValue,
            title: $0.title,
            systemImage: $0.systemImage
          )
        },
        sessions: store.sessions,
        taskBoardItems: store.globalTaskBoardItems,
        decisions: store.supervisorOpenDecisionPresentationItems,
        reviews: reviewRegistry.loadedItems,
        loadedSession: loadedSessionSnapshot,
        showsPolicyCanvasLab: showsPolicyCanvasLab
      )
    )
  }

  private var loadedSessionSnapshot: OpenAnythingLoadedSessionSnapshot? {
    guard let sessionID = store.selectedSessionID else { return nil }
    return OpenAnythingLoadedSessionSnapshot(
      sessionID: sessionID,
      agents: store.selectedSessionAgents,
      tasks: store.selectedSessionTasks,
      timeline: store.timeline
    )
  }
}

struct HarnessMonitorOpenAnythingHostModifier: ViewModifier {
  let windowID: String
  let model: OpenAnythingPaletteModel
  let reviewRegistry: OpenAnythingDashboardReviewRegistry
  let store: HarnessMonitorStore
  let keyWindowObserver: KeyWindowObserver
  let windowNavigationHistory: GlobalWindowNavigationHistory
  let showsPolicyCanvasLab: Bool
  let refreshStore: () -> Void
  @Binding var settingsSelectedSection: SettingsSection
  @Binding var settingsNavigationRequest: SettingsNavigationRequest?
  @Environment(\.openWindow)
  private var openWindow

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    let showing = model.isPresented(
      in: windowID,
      isKeyWindow: keyWindowObserver.isKey(windowID: windowID)
    )
    return content
      .overlay {
        if showing {
          OpenAnythingPaletteView(model: model, execute: execute)
            .zIndex(1_000)
        }
      }
      .animation(
        showing
          ? OpenAnythingMotionPolicy.presentAnimation(reduceMotion: reduceMotion)
          : OpenAnythingMotionPolicy.dismissAnimation(reduceMotion: reduceMotion),
        value: showing
      )
  }

  private func execute(_ hit: OpenAnythingHit) {
    // Audit #43: the `steps(for: hit, ...)` wrapper just forwarded to
    // `steps(for: target, ...)`. Inlined here so the executor surface is a
    // single entry point keyed on `OpenAnythingTarget`.
    for step in OpenAnythingRouteExecutor.steps(
      for: hit.target,
      showsPolicyCanvasLab: showsPolicyCanvasLab
    ) {
      executeRoutingStep(step)
    }
  }

  private func executeRoutingStep(_ step: OpenAnythingRoutingStep) {
    guard !executePresentationStep(step) else { return }
    guard !executeCommandStep(step) else { return }
    switch step {
    case .openWindow(let target):
      openWindowTarget(target)
    case .openDashboard(let route):
      openDashboard(route)
    case .openSettings(let rawValue):
      openSettings(rawValue: rawValue)
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
    // Audit #77: deep-link steps. No current target emits these - they are
    // hooks for row context-menu actions in the palette view ("Open in
    // browser", "Reveal in Finder"). Treated as command-type steps so the
    // routing switch below stays a navigation-only fallback.
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

  private func openWindowTarget(_ target: OpenAnythingWindowTarget) {
    switch target {
    case .dashboard:
      openWindow.openHarnessDashboardWindow()
    case .settings:
      openWindow(id: HarnessMonitorWindowID.settings)
    case .policyCanvasLab:
      if showsPolicyCanvasLab {
        openWindow(id: HarnessMonitorWindowID.policyCanvasLab)
      }
    }
  }

  private func openDashboard(_ route: OpenAnythingDashboardRoute) {
    let dashboardRoute = DashboardWindowRoute(rawValue: route.rawValue) ?? .taskBoard
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

  private func openSettings(rawValue: String) {
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
    }
  }
}
