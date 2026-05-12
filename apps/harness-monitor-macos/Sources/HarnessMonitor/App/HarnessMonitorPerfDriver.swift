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
    private static let signpostBridge = HarnessMonitorSignpostBridge(
      subsystem: "io.harnessmonitor",
      category: "perf"
    )
  #else
    private static let signposter = OSSignposter(
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

  private static func envMilliseconds(_ key: String, fallback: Int) -> Duration {
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
      result = await signpostBridge.withInterval(
        name: scenario.signpostName,
        flushOnCompletion: true
      ) {
        await runScenario(scenario, store: store, openWindow: openWindow)
      }
    #else
      let state = signposter.beginInterval(scenario.signpostName, id: .exclusive)
      defer { signposter.endInterval(scenario.signpostName, state) }
      result = await runScenario(scenario, store: store, openWindow: openWindow)
    #endif
    return result
  }

  private static func runScenario(
    _ scenario: HarnessMonitorPerfScenario,
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
    switch scenario {
    case .openRecentWindow, .openSessionWindow, .offlineCachedOpen:
      return await runWindowScenario(scenario, store: store, openWindow: openWindow)
    case .agentDetailForm, .decisionDetailForm, .taskDetailForm, .permissionModal:
      return await runDetailRoutingScenario(scenario, store: store, openWindow: openWindow)
    case .sessionSearchFull, .timelineFilterForm, .timelineBurst, .toastOverlayChurn:
      return await runSessionUtilityScenario(scenario, store: store, openWindow: openWindow)
    case .settingsBackdropCycle, .settingsBackgroundCycle:
      return await runSettingsScenario(scenario, openWindow: openWindow)
    }
  }

  private static func runWindowScenario(
    _ scenario: HarnessMonitorPerfScenario,
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
    switch scenario {
    case .openRecentWindow:
      return await runOpenRecentWindowScenario(store: store)
    case .openSessionWindow:
      return await openSessionWindow(
        sessionID: PreviewFixtures.summary.sessionId,
        store: store,
        openWindow: openWindow
      )
    case .offlineCachedOpen:
      return await openSessionWindow(
        sessionID: PreviewFixtures.summary.sessionId,
        store: store,
        openWindow: openWindow
      )
    default:
      return .failed("Unsupported window scenario \(scenario.rawValue)")
    }
  }

  private static func runDetailRoutingScenario(
    _ scenario: HarnessMonitorPerfScenario,
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
    switch scenario {
    case .agentDetailForm:
      return await routeAgentDetailFormScenario(store: store, openWindow: openWindow)
    case .decisionDetailForm:
      return await routeDecisionDetailFormScenario(store: store, openWindow: openWindow)
    case .taskDetailForm:
      return await routeTaskDetailFormScenario(store: store, openWindow: openWindow)
    case .permissionModal:
      return await routePermissionDecisionToWorkspace(
        store: store,
        openWindow: openWindow
      )
    default:
      return .failed("Unsupported detail routing scenario \(scenario.rawValue)")
    }
  }

  private static func runSessionUtilityScenario(
    _ scenario: HarnessMonitorPerfScenario,
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
    switch scenario {
    case .sessionSearchFull:
      return await runSessionSearchFullScenario(store: store, openWindow: openWindow)
    case .timelineFilterForm:
      return await runTimelineFilterFormScenario(store: store, openWindow: openWindow)
    case .timelineBurst:
      return await runTimelineBurstScenario(store: store, openWindow: openWindow)
    case .toastOverlayChurn:
      return await runToastOverlayChurnScenario(store: store, openWindow: openWindow)
    default:
      return .failed("Unsupported session utility scenario \(scenario.rawValue)")
    }
  }

  private static func runSettingsScenario(
    _ scenario: HarnessMonitorPerfScenario,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
    switch scenario {
    case .settingsBackdropCycle:
      return await runSettingsBackdropCycleScenario(openWindow: openWindow)
    case .settingsBackgroundCycle:
      return await runSettingsBackgroundCycleScenario(openWindow: openWindow)
    default:
      return .failed("Unsupported settings scenario \(scenario.rawValue)")
    }
  }

}
