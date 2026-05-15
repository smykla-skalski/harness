import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

@MainActor
extension HarnessMonitorPerfDriver {
  static func settle(_ delay: Duration? = nil) async {
    try? await Task.sleep(for: delay ?? settleDelay)
  }

  static func runOpenRecentWindowScenario(
    store: HarnessMonitorStore
  ) async -> ScenarioResult {
    await store.bootstrapIfNeeded()
    await store.prepareOpenRecentSessions()
    await settle()
    return .completed
  }

  static func runPolicyCanvasScenario(
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
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
    await settle(.milliseconds(1_400))
    return .completed
  }

  static func runSettingsBackdropCycleScenario(
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
    await openAppearanceSettings(openWindow: openWindow)
    await cycleBackdropModes()
    return .completed
  }

  static func runSettingsBackgroundCycleScenario(
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
    await openAppearanceSettings(openWindow: openWindow)
    await cycleBackgroundSelections()
    return .completed
  }

  static func runTaskBoardSettingsScenario(
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
    await openSettingsWindow(openWindow: openWindow)
    return .completed
  }

  static func runTimelineBurstScenario(
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
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
  }

  static func routeAgentDetailFormScenario(
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
    await routePreviewSessionSelection(
      .agent(
        sessionID: PreviewFixtures.summary.sessionId,
        agentID: PreviewFixtures.agents[1].agentId
      ),
      store: store,
      openWindow: openWindow
    )
  }

  static func routeDecisionDetailFormScenario(
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
    await routePermissionDecisionToWorkspace(store: store, openWindow: openWindow)
  }

  static func routeTaskDetailFormScenario(
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
    await routePreviewSessionSelection(
      .task(
        sessionID: PreviewFixtures.summary.sessionId,
        taskID: PreviewFixtures.tasks[0].taskId
      ),
      store: store,
      openWindow: openWindow
    )
  }

  static func runSessionSearchFullScenario(
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
    guard
      await ensureSessionWindow(
        sessionID: PreviewFixtures.summary.sessionId,
        store: store,
        openWindow: openWindow
      )
    else {
      return .failed("session-window-timeout")
    }
    await settle(.milliseconds(1_400))
    return .completed
  }

  static func runTimelineFilterFormScenario(
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
    guard
      await ensureSessionWindow(
        sessionID: PreviewFixtures.summary.sessionId,
        store: store,
        openWindow: openWindow
      )
    else {
      return .failed("session-window-timeout")
    }
    await settle(.milliseconds(1_000))
    return .completed
  }

  static func runToastOverlayChurnScenario(
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
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
  }

  static func openSessionWindow(
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

  static func routePreviewSessionSelection(
    _ selection: SessionRouteSelection,
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
    store.requestSessionRoute(selection)
    guard
      await ensureSessionWindow(
        sessionID: PreviewFixtures.summary.sessionId,
        store: store,
        openWindow: openWindow
      )
    else {
      return .failed("session-window-timeout")
    }
    await settle()
    return .completed
  }

  static func routePermissionDecisionToWorkspace(
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async -> ScenarioResult {
    await settle()
    HarnessMonitorPerfTrace.recordScenarioEvent(
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
      HarnessMonitorPerfTrace.recordScenarioEvent(
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
    HarnessMonitorPerfTrace.recordScenarioEvent(
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
      HarnessMonitorPerfTrace.recordScenarioEvent(
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
    HarnessMonitorPerfTrace.recordScenarioEvent(
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

  static func waitForRoutedWorkspaceDecision(
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

  static func shouldWaitForRoutedWorkspaceDecision(
    decisionID: String,
    store: HarnessMonitorStore
  ) -> Bool {
    let hasOpenDecision = store.supervisorOpenDecisions.contains { $0.id == decisionID }
    return store.supervisorSelectedDecisionID != decisionID || !hasOpenDecision
  }

  static func ensureSessionWindow(
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

  static func waitForSessionWindow(
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

}
