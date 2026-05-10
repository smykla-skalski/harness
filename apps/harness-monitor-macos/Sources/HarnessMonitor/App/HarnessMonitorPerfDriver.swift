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
  private static let sessionWindowTimeout = Duration.seconds(3)

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
    case .openRecentWindow:
      await store.bootstrapIfNeeded()
      await store.prepareOpenRecentSessions()
      await settle()
      return .completed
    case .openSessionWindow:
      return await openSessionWindow(
        sessionID: PreviewFixtures.summary.sessionId,
        store: store,
        openWindow: openWindow
      )
    case .permissionModal:
      return await routePermissionDecisionToWorkspace(
        store: store,
        openWindow: openWindow
      )
    case .settingsBackdropCycle:
      await openAppearanceSettings(openWindow: openWindow)
      await cycleBackdropModes()
      return .completed
    case .settingsBackgroundCycle:
      await openAppearanceSettings(openWindow: openWindow)
      await cycleBackgroundSelections()
      return .completed
    case .timelineBurst:
      let sessionID = PreviewFixtures.summary.sessionId
      guard
        await ensureSessionWindow(
          sessionID: sessionID,
          store: store,
          openWindow: openWindow
        )
      else {
        return .failed("session-window-timeout")
      }
      guard await burstTimeline(sessionID: sessionID, store: store) else {
        return .failed("preview-timeline-unavailable")
      }
      return .completed
    case .toastOverlayChurn:
      guard
        await ensureSessionWindow(
          sessionID: PreviewFixtures.summary.sessionId,
          store: store,
          openWindow: openWindow
        )
      else {
        return .failed("session-window-timeout")
      }
      await churnToastOverlay(store: store)
      return .completed
    case .offlineCachedOpen:
      return await openSessionWindow(
        sessionID: PreviewFixtures.summary.sessionId,
        store: store,
        openWindow: openWindow
      )
    }
  }

  private static func settle(_ delay: Duration? = nil) async {
    try? await Task.sleep(for: delay ?? settleDelay)
  }

  private static func openSessionWindow(
    sessionID: String,
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
    guard
      await ensureSessionWindow(
        sessionID: sessionID,
        store: store,
        openWindow: openWindow
      )
    else {
      return .failed("session-window-timeout")
    }
    return .completed
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
    openWindow.openHarnessDecisionSession(decisionID: decisionID, store: store)
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
        "ACP decision \(decisionID, privacy: .public) failed to route into Workspace"
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
    guard
      let sessionID =
        store.supervisorOpenDecisions.first(where: { $0.id == decisionID })?.sessionID
        ?? store.selectedSessionID
    else {
      HarnessMonitorLogger.store.error(
        "ACP decision \(decisionID, privacy: .public) routed without a session window target"
      )
      await settle()
      return .failed("missing-session-id")
    }
    guard await waitForSessionWindow(sessionID: sessionID, store: store) else {
      let sid = sessionID
      HarnessMonitorLogger.store.error(
        "ACP \(decisionID, privacy: .public) session window timeout for \(sid, privacy: .public)"
      )
      await settle(.milliseconds(1_000))
      return .failed("session-window-timeout")
    }
    await settle()
    return .completed
  }

  private static func waitForRoutedWorkspaceDecision(
    decisionID: String,
    store: HarnessMonitorStore
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: routeTimeout)
    while shouldWaitForRoutedWorkspaceDecision(decisionID: decisionID, store: store) {
      guard clock.now < deadline else {
        return false
      }
      try? await Task.sleep(for: shortDelay)
    }
    return true
  }

  private static func shouldWaitForRoutedWorkspaceDecision(
    decisionID: String,
    store: HarnessMonitorStore
  ) -> Bool {
    let hasOpenDecision = store.supervisorOpenDecisions.contains { $0.id == decisionID }
    return store.supervisorSelectedDecisionID != decisionID || !hasOpenDecision
  }

  private static func ensureSessionWindow(
    sessionID: String,
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> Bool {
    if store.openSessionWindowIDsSnapshot.contains(sessionID) {
      await settle()
      return true
    }

    await store.prepareOpenRecentSessions()
    await settle()
    openWindow.openHarnessSessionWindow(sessionID: sessionID)
    guard await waitForSessionWindow(sessionID: sessionID, store: store) else {
      return false
    }
    await settle()
    return true
  }

  private static func waitForSessionWindow(
    sessionID: String,
    store: HarnessMonitorStore
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: sessionWindowTimeout)
    while store.openSessionWindowIDsSnapshot.contains(sessionID) == false {
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
    openWindow(id: HarnessMonitorWindowID.settings)
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

  private static func burstTimeline(
    sessionID: String,
    store: HarnessMonitorStore
  ) async -> Bool {
    for batch in 1...8 {
      guard
        await store.replacePreviewTimeline(
          sessionID: sessionID,
          entries: PreviewFixtures.timelineBurst(batch: batch)
        )
      else {
        HarnessMonitorLogger.store.error(
          "Timeline perf scenario requires a preview session snapshot for \(sessionID, privacy: .public)"
        )
        return false
      }
      try? await Task.sleep(for: shortDelay)
    }
    await settle()
    return true
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
    case .openRecentWindow:
      true
    case .openSessionWindow,
      .permissionModal,
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
    case .openRecentWindow: "open-recent-window"
    case .openSessionWindow: "open-session-window"
    case .permissionModal: "permission-modal"
    case .settingsBackdropCycle: "settings-backdrop-cycle"
    case .settingsBackgroundCycle: "settings-background-cycle"
    case .timelineBurst: "timeline-burst"
    case .toastOverlayChurn: "toast-overlay-churn"
    case .offlineCachedOpen: "offline-cached-open"
    }
  }
}
