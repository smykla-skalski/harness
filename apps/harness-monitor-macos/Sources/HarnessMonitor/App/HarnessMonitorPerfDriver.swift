import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import OSLog
import SwiftUI

@MainActor
enum HarnessMonitorPerfDriver {
  enum ScenarioResult {
    case completed
    case failed(String)
  }

  #if HARNESS_FEATURE_OTEL
    static let signpostBridge = HarnessMonitorSignpostBridge(
      subsystem: "io.harnessmonitor",
      category: "perf"
    )
  #else
    static let signposter = OSSignposter(
      subsystem: "io.harnessmonitor",
      category: "perf"
    )
  #endif
  static let stepDelay: Duration = envMilliseconds(
    "HARNESS_MONITOR_PERF_STEP_DELAY_MS", fallback: 450
  )
  static let shortDelay: Duration = envMilliseconds(
    "HARNESS_MONITOR_PERF_SHORT_DELAY_MS", fallback: 180
  )
  static let settleDelay: Duration = envMilliseconds(
    "HARNESS_MONITOR_PERF_SETTLE_DELAY_MS", fallback: 900
  )
  static let routeTimeout = Duration.seconds(2)
  static let sessionWindowTimeout = Duration.seconds(3)

  static func envMilliseconds(_ key: String, fallback: Int) -> Duration {
    guard let raw = ProcessInfo.processInfo.environment[key],
      let value = Int(raw), value > 0
    else {
      return .milliseconds(fallback)
    }
    return .milliseconds(value)
  }

  static func run(
    scenario: HarnessMonitorPerfScenario,
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
    let result: ScenarioResult
    #if HARNESS_FEATURE_OTEL
      result = await signpostBridge.withAnimationInterval(
        name: scenario.signpostName,
        flushOnCompletion: true
      ) {
        await runScenario(scenario, store: store, openWindow: openWindow)
      }
    #else
      let state = signposter.beginAnimationInterval(scenario.signpostName, id: .exclusive)
      defer { signposter.endInterval(scenario.signpostName, state) }
      result = await runScenario(scenario, store: store, openWindow: openWindow)
    #endif
    return result
  }

  static func runScenario(
    _ scenario: HarnessMonitorPerfScenario,
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
    if let result = await runWindowScenario(scenario, store: store, openWindow: openWindow) {
      return result
    }
    if let result = await runDetailScenario(scenario, store: store, openWindow: openWindow) {
      return result
    }
    if let result = await runSettingsScenario(scenario, openWindow: openWindow) {
      return result
    }
    return await runActivityScenario(scenario, store: store, openWindow: openWindow)
  }

  static func runWindowScenario(
    _ scenario: HarnessMonitorPerfScenario,
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult? {
    switch scenario {
    case .openRecentWindow:
      return await runOpenRecentWindowScenario(store: store)
    case .openSessionWindow,
      .openSessionWindowVisualOptionsDisabled,
      .offlineCachedOpen:
      return await openSessionWindow(
        sessionID: PreviewFixtures.summary.sessionId,
        store: store,
        openWindow: openWindow
      )
    case .sidebarToggleRichDetail,
      .sidebarToggleRichDetailVisualsOff:
      guard
        await ensureSessionWindow(
          sessionID: PreviewFixtures.summary.sessionId,
          store: store,
          openWindow: openWindow
        )
      else {
        return .failed("session-window-timeout")
      }
      await settle(.milliseconds(2_800))
      return .completed
    case .dashboardSearchSuggestions:
      return await runDashboardSearchSuggestionsScenario(store: store)
    case .dashboardLiveScroll:
      return await runDashboardLiveScrollScenario(store: store)
    case .dashboardLiveInteract:
      return await runDashboardLiveInteractScenario(store: store)
    case .policyCanvas,
      .agentDetailForm,
      .agentDetailFormVisualOptionsDisabled,
      .decisionDetailForm,
      .decisionDetailFormVisualOptionsDisabled,
      .taskDetailForm,
      .taskDetailFormVisualOptionsDisabled,
      .sessionSearchFull,
      .sessionSearchFullVisualOptionsDisabled,
      .timelineFilterForm,
      .timelineFilterFormVisualOptionsDisabled,
      .permissionModal,
      .taskBoardSettings,
      .repositoriesSettings,
      .dependenciesSettings,
      .settingsBackdropCycle,
      .settingsBackgroundCycle,
      .timelineBurst,
      .toastOverlayChurn:
      return nil
    }
  }

  static func runDetailScenario(
    _ scenario: HarnessMonitorPerfScenario,
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult? {
    switch scenario {
    case .policyCanvas:
      return await runPolicyCanvasScenario(store: store, openWindow: openWindow)
    case .agentDetailForm,
      .agentDetailFormVisualOptionsDisabled:
      return await routeAgentDetailFormScenario(store: store, openWindow: openWindow)
    case .decisionDetailForm,
      .decisionDetailFormVisualOptionsDisabled:
      return await routeDecisionDetailFormScenario(store: store, openWindow: openWindow)
    case .taskDetailForm,
      .taskDetailFormVisualOptionsDisabled:
      return await routeTaskDetailFormScenario(store: store, openWindow: openWindow)
    case .sessionSearchFull,
      .sessionSearchFullVisualOptionsDisabled:
      return await runSessionSearchFullScenario(store: store, openWindow: openWindow)
    case .timelineFilterForm,
      .timelineFilterFormVisualOptionsDisabled:
      return await runTimelineFilterFormScenario(store: store, openWindow: openWindow)
    case .permissionModal:
      return await routePermissionDecisionToWorkspace(
        store: store,
        openWindow: openWindow
      )
    case .openRecentWindow,
      .openSessionWindow,
      .openSessionWindowVisualOptionsDisabled,
      .sidebarToggleRichDetail,
      .sidebarToggleRichDetailVisualsOff,
      .settingsBackdropCycle,
      .settingsBackgroundCycle,
      .taskBoardSettings,
      .repositoriesSettings,
      .dependenciesSettings,
      .timelineBurst,
      .toastOverlayChurn,
      .offlineCachedOpen,
      .dashboardSearchSuggestions,
      .dashboardLiveScroll,
      .dashboardLiveInteract:
      return nil
    }
  }

  static func runSettingsScenario(
    _ scenario: HarnessMonitorPerfScenario,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult? {
    switch scenario {
    case .taskBoardSettings,
      .repositoriesSettings,
      .dependenciesSettings:
      return await runTaskBoardSettingsScenario(openWindow: openWindow)
    case .settingsBackdropCycle:
      return await runSettingsBackdropCycleScenario(openWindow: openWindow)
    case .settingsBackgroundCycle:
      return await runSettingsBackgroundCycleScenario(openWindow: openWindow)
    case .openRecentWindow,
      .openSessionWindow,
      .openSessionWindowVisualOptionsDisabled,
      .policyCanvas,
      .agentDetailForm,
      .agentDetailFormVisualOptionsDisabled,
      .decisionDetailForm,
      .decisionDetailFormVisualOptionsDisabled,
      .taskDetailForm,
      .taskDetailFormVisualOptionsDisabled,
      .sessionSearchFull,
      .sessionSearchFullVisualOptionsDisabled,
      .sidebarToggleRichDetail,
      .sidebarToggleRichDetailVisualsOff,
      .timelineFilterForm,
      .timelineFilterFormVisualOptionsDisabled,
      .permissionModal,
      .timelineBurst,
      .toastOverlayChurn,
      .offlineCachedOpen,
      .dashboardSearchSuggestions,
      .dashboardLiveScroll,
      .dashboardLiveInteract:
      return nil
    }
  }

  static func runActivityScenario(
    _ scenario: HarnessMonitorPerfScenario,
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
    switch scenario {
    case .timelineBurst:
      return await runTimelineBurstScenario(store: store, openWindow: openWindow)
    case .toastOverlayChurn:
      return await runToastOverlayChurnScenario(store: store, openWindow: openWindow)
    case .openRecentWindow,
      .openSessionWindow,
      .openSessionWindowVisualOptionsDisabled,
      .policyCanvas,
      .agentDetailForm,
      .agentDetailFormVisualOptionsDisabled,
      .decisionDetailForm,
      .decisionDetailFormVisualOptionsDisabled,
      .taskDetailForm,
      .taskDetailFormVisualOptionsDisabled,
      .sessionSearchFull,
      .sessionSearchFullVisualOptionsDisabled,
      .sidebarToggleRichDetail,
      .sidebarToggleRichDetailVisualsOff,
      .timelineFilterForm,
      .timelineFilterFormVisualOptionsDisabled,
      .permissionModal,
      .taskBoardSettings,
      .repositoriesSettings,
      .dependenciesSettings,
      .settingsBackdropCycle,
      .settingsBackgroundCycle,
      .offlineCachedOpen,
      .dashboardSearchSuggestions,
      .dashboardLiveScroll,
      .dashboardLiveInteract:
      return .failed("unsupported-scenario")
    }
  }

}
