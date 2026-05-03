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
  private static let stepDelay: Duration = envMilliseconds(
    "HARNESS_MONITOR_PERF_STEP_DELAY_MS", fallback: 450
  )
  private static let shortDelay: Duration = envMilliseconds(
    "HARNESS_MONITOR_PERF_SHORT_DELAY_MS", fallback: 180
  )
  private static let settleDelay: Duration = envMilliseconds(
    "HARNESS_MONITOR_PERF_SETTLE_DELAY_MS", fallback: 900
  )
  private static let routeTimeout = Duration.seconds(2)

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
    case .launchDashboard:
      await store.bootstrapIfNeeded()
      await settle()
      return .completed
    case .selectSessionCockpit:
      await settle()
      await store.selectSession(PreviewFixtures.summary.sessionId)
      await settle()
      return .completed
    case .permissionModal:
      return await routePermissionDecisionToWorkspace(
        store: store,
        openWindow: openWindow
      )
    case .refreshAndSearch:
      await settle()
      await store.refresh()
      await runSearchPasses(
        queries: ["timeline", "observer", "blocked"],
        store: store
      )
      return .completed
    case .sidebarOverflowSearch:
      await settle()
      await runSearchPasses(
        queries: ["sidebar", "search", "observer", "blocked", "transport"],
        store: store
      )
      return .completed
    case .settingsBackdropCycle:
      await openAppearanceSettings(openWindow: openWindow)
      await cycleBackdropModes()
      return .completed
    case .settingsBackgroundCycle:
      await openAppearanceSettings(openWindow: openWindow)
      await cycleBackgroundSelections()
      return .completed
    case .timelineBurst:
      await settle()
      await store.selectSession(PreviewFixtures.summary.sessionId)
      await burstTimeline(store: store)
      return .completed
    case .toastOverlayChurn:
      await settle()
      await store.selectSession(PreviewFixtures.summary.sessionId)
      await churnToastOverlay(store: store)
      return .completed
    case .offlineCachedOpen:
      await settle()
      return .completed
    }
  }

  private static func settle(_ delay: Duration? = nil) async {
    try? await Task.sleep(for: delay ?? settleDelay)
  }

  private static func runSearchPasses(
    queries: [String],
    store: HarnessMonitorStore
  ) async {
    for query in queries {
      store.searchText = query
      try? await Task.sleep(for: stepDelay)
    }
    store.searchText = ""
    await settle()
  }

  private static func routePermissionDecisionToWorkspace(
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
    await settle()
    HarnessMonitorUITestTrace.record(
      component: "perf.permission-modal",
      event: "route.inspect",
      details: [
        "selected_acp_agents": String(store.selectedAcpAgents.count),
        "pending_batches": String(store.pendingAcpPermissionBatches.count),
        "decision_store_ready": String(store.supervisorDecisionStore != nil),
      ]
    )
    guard
      let batch = store.selectedAcpAgents
        .flatMap(\.pendingPermissionBatches)
        .first
    else {
      HarnessMonitorUITestTrace.record(
        component: "perf.permission-modal",
        event: "route.missing-batch",
        details: [
          "selected_acp_agents": String(store.selectedAcpAgents.count),
          "pending_batches": String(store.pendingAcpPermissionBatches.count),
        ]
      )
      HarnessMonitorLogger.store.error(
        "Permission-modal perf scenario missing a seeded ACP permission batch"
      )
      await settle()
      return .failed("missing-acp-batch")
    }
    // The roadmap still calls this path "permission-modal", but the live app now
    // routes ACP prompts straight into Workspace decisions instead of showing a sheet.
    let decisionID = AcpPermissionDecisionPayload.decisionID(for: batch.batchId)
    HarnessMonitorUITestTrace.record(
      component: "perf.permission-modal",
      event: "route.begin",
      details: [
        "batch_id": batch.batchId,
        "decision_id": decisionID,
        "decision_store_ready": String(store.supervisorDecisionStore != nil),
        "open_decision_count": String(store.supervisorOpenDecisions.count),
      ]
    )
    store.presentingAcpPermissionBatch = batch
    openWindow(id: HarnessMonitorWindowID.workspace)
    guard await waitForRoutedWorkspaceDecision(decisionID: decisionID, store: store) else {
      HarnessMonitorUITestTrace.record(
        component: "perf.permission-modal",
        event: "route.timeout",
        details: [
          "decision_id": decisionID,
          "selected_decision_id": store.supervisorSelectedDecisionID ?? "none",
          "open_decisions": store.supervisorOpenDecisions.map(\.id).joined(separator: ","),
        ]
      )
      HarnessMonitorLogger.store.error(
        "Permission-modal perf scenario failed to route ACP decision \(decisionID, privacy: .public) into Workspace"
      )
      await settle(.milliseconds(1_000))
      return .failed("route-timeout")
    }
    HarnessMonitorUITestTrace.record(
      component: "perf.permission-modal",
      event: "route.ready",
      details: [
        "decision_id": decisionID,
        "selected_decision_id": store.supervisorSelectedDecisionID ?? "none",
        "open_decision_count": String(store.supervisorOpenDecisions.count),
      ]
    )
    await settle()
    return .completed
  }

  private static func waitForRoutedWorkspaceDecision(
    decisionID: String,
    store: HarnessMonitorStore
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: routeTimeout)
    while
      store.supervisorSelectedDecisionID != decisionID
        || store.supervisorOpenDecisions.contains(where: { $0.id == decisionID }) == false
    {
      guard clock.now < deadline else {
        return false
      }
      try? await Task.sleep(for: shortDelay)
    }
    return true
  }

  private static func openAppearanceSettings(openWindow: OpenWindowAction) async {
    UserDefaults.standard.set(
      HarnessMonitorBackdropMode.window.rawValue,
      forKey: HarnessMonitorBackdropDefaults.modeKey
    )
    openWindow(id: HarnessMonitorWindowID.preferences)
    await settle(.milliseconds(1_000))
  }

  private static func cycleBackdropModes() async {
    for mode in HarnessMonitorBackdropMode.allCases + [.window, .content] {
      UserDefaults.standard.set(mode.rawValue, forKey: HarnessMonitorBackdropDefaults.modeKey)
      try? await Task.sleep(for: stepDelay)
    }
    await settle()
  }

  private static func cycleBackgroundSelections() async {
    UserDefaults.standard.set(
      HarnessMonitorBackdropMode.window.rawValue,
      forKey: HarnessMonitorBackdropDefaults.modeKey
    )

    let backgrounds =
      Array(
        HarnessMonitorBackgroundSelection.bundledLibrary.prefix(6)
      ) + [HarnessMonitorBackgroundSelection.defaultSelection]

    for background in backgrounds {
      UserDefaults.standard.set(
        background.storageValue,
        forKey: HarnessMonitorBackgroundDefaults.imageKey
      )
      try? await Task.sleep(for: stepDelay)
    }

    await settle()
  }

  private static func burstTimeline(store: HarnessMonitorStore) async {
    for batch in 1...8 {
      store.timeline = PreviewFixtures.timelineBurst(batch: batch)
      try? await Task.sleep(for: shortDelay)
    }
    await settle()
  }

  private static func churnToastOverlay(store: HarnessMonitorStore) async {
    let firstToast = store.presentSuccessFeedback("Observe session")
    try? await Task.sleep(for: shortDelay)

    let secondToast = store.presentFailureFeedback("Create task failed")
    try? await Task.sleep(for: shortDelay)

    let thirdToast = store.presentSuccessFeedback("Copied session ID")
    try? await Task.sleep(for: shortDelay)

    store.dismissFeedback(id: secondToast)
    try? await Task.sleep(for: shortDelay)

    let fourthToast = store.presentFailureFeedback("Observer unavailable")
    try? await Task.sleep(for: shortDelay)

    store.dismissFeedback(id: firstToast)
    try? await Task.sleep(for: shortDelay)

    store.dismissFeedback(id: fourthToast)
    try? await Task.sleep(for: shortDelay)

    store.dismissFeedback(id: thirdToast)
    await settle()
  }
}

extension HarnessMonitorPerfScenario {
  var includesBootstrapInMeasurement: Bool {
    switch self {
    case .launchDashboard:
      true
    case .selectSessionCockpit,
      .permissionModal,
      .refreshAndSearch,
      .sidebarOverflowSearch,
      .settingsBackdropCycle,
      .settingsBackgroundCycle,
      .timelineBurst,
      .toastOverlayChurn,
      .offlineCachedOpen:
      false
    }
  }

  var signpostName: StaticString {
    switch self {
    case .launchDashboard: "launch-dashboard"
    case .selectSessionCockpit: "select-session-cockpit"
    case .permissionModal: "permission-modal"
    case .refreshAndSearch: "refresh-and-search"
    case .sidebarOverflowSearch: "sidebar-overflow-search"
    case .settingsBackdropCycle: "settings-backdrop-cycle"
    case .settingsBackgroundCycle: "settings-background-cycle"
    case .timelineBurst: "timeline-burst"
    case .toastOverlayChurn: "toast-overlay-churn"
    case .offlineCachedOpen: "offline-cached-open"
    }
  }
}
