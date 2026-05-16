import Foundation
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

@MainActor
extension HarnessMonitorPerfDriver {
  /// Drives the dashboard window against the real external daemon and exercises
  /// the surface beyond a pure scroll: scroll bottom, scroll top, flip the
  /// sidebar route (task-board -> policy-canvas -> task-board), then a final
  /// scroll burst. Requires `HARNESS_MONITOR_LAUNCH_MODE=live` plus a reachable
  /// daemon (same envelope as `dashboard-live-scroll`).
  static func runDashboardLiveInteractScenario(
    store: HarnessMonitorStore
  ) async -> ScenarioResult {
    let launchMode = HarnessMonitorLaunchMode(environment: ProcessInfo.processInfo.environment)
    guard launchMode == .live else {
      HarnessMonitorLogger.store.error(
        "dashboard-live-interact scenario requires HARNESS_MONITOR_LAUNCH_MODE=live"
      )
      return .failed("launch-mode-not-live")
    }

    await store.bootstrapIfNeeded()
    guard await waitForLiveInteractDashboardReady(store: store) else {
      HarnessMonitorPerfTrace.recordScenarioEvent(
        component: "perf.dashboard-live-interact",
        event: "wait.timeout",
        details: [
          "connection_state": String(describing: store.connectionState),
          "recent_session_count": String(store.recentSessions.count),
        ]
      )
      return .failed("daemon-not-ready")
    }

    HarnessMonitorPerfTrace.recordScenarioEvent(
      component: "perf.dashboard-live-interact",
      event: "ready",
      details: [
        "connection_state": String(describing: store.connectionState),
        "recent_session_count": String(store.recentSessions.count),
      ]
    )

    let scrollable = await waitForLiveInteractScrollableContent(timeout: .seconds(6))

    HarnessMonitorPerfTrace.recordScenarioEvent(
      component: "perf.dashboard-live-interact",
      event: scrollable ? "scrollable" : "non-scrollable",
      details: [
        "content_h":
          String(Int(HarnessMonitorPerfDashboardScrollBus.latestGeometry.contentHeight.rounded())),
        "container_h":
          String(
            Int(HarnessMonitorPerfDashboardScrollBus.latestGeometry.containerHeight.rounded())),
      ]
    )

    // Pass 1: outer dashboard scroll, mirrors landing-on-surface behavior.
    postInteractScrollEvent(.bottom, pass: 1)
    await settle(.milliseconds(900))

    postInteractScrollEvent(.top, pass: 1)
    await settle(.milliseconds(700))

    // Pass 2: scroll the Needs You column on its own — its inner ScrollView is
    // the surface users actually drag while triaging decisions, and it tends to
    // stutter independently of the outer dashboard scroll.
    postLaneScrollRequest(lane: "needs_you", edge: "bottom")
    await settle(.milliseconds(900))

    postLaneScrollRequest(lane: "needs_you", edge: "top")
    await settle(.milliseconds(700))

    // Pass 3: flip into Policy Canvas — exercises route swap + dashboard tear-down.
    postInteractRouteRequest("policyCanvas")
    await settle(.milliseconds(1_400))

    // Pass 4: back to Task Board — exercises re-entry + scroll surface rebuild.
    postInteractRouteRequest("taskBoard")
    await settle(.milliseconds(900))

    // Pass 5: final outer scroll burst on the rebuilt surface.
    postInteractScrollEvent(.bottom, pass: 2)
    await settle(.milliseconds(900))

    postInteractScrollEvent(.top, pass: 2)
    await settle(.milliseconds(700))

    return .completed
  }

  private static func waitForLiveInteractScrollableContent(
    timeout: Duration
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !HarnessMonitorPerfDashboardScrollBus.latestGeometry.isScrollable {
      guard clock.now < deadline else {
        return false
      }
      try? await Task.sleep(for: shortDelay)
    }
    return true
  }

  private enum LiveInteractDirection: String {
    case top
    case bottom
  }

  private static func postInteractScrollEvent(
    _ direction: LiveInteractDirection,
    pass: Int
  ) {
    HarnessMonitorPerfTrace.recordScenarioEvent(
      component: "perf.dashboard-live-interact",
      event: "scroll.post.\(direction.rawValue)",
      details: ["pass": String(pass)]
    )
    let name: Notification.Name
    switch direction {
    case .top:
      name = HarnessMonitorPerfDashboardScrollBus.scrollToTop
    case .bottom:
      name = HarnessMonitorPerfDashboardScrollBus.scrollToBottom
    }
    NotificationCenter.default.post(name: name, object: nil)
  }

  private static func postInteractRouteRequest(_ raw: String) {
    HarnessMonitorPerfDashboardRouteBus.requestRoute(raw: raw)
  }

  private static func postLaneScrollRequest(lane: String, edge: String) {
    HarnessMonitorPerfTrace.recordScenarioEvent(
      component: "perf.dashboard-live-interact",
      event: "lane.scroll.post.\(edge)",
      details: ["lane": lane]
    )
    HarnessMonitorPerfTaskBoardLaneScrollBus.requestScroll(laneRaw: lane, edge: edge)
  }

  private static func waitForLiveInteractDashboardReady(
    store: HarnessMonitorStore
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(8))
    while !isLiveInteractDashboardReady(store: store) {
      guard clock.now < deadline else {
        return false
      }
      try? await Task.sleep(for: shortDelay)
    }
    return true
  }

  private static func isLiveInteractDashboardReady(
    store: HarnessMonitorStore
  ) -> Bool {
    switch store.connectionState {
    case .online:
      return true
    case .offline:
      // Mirror live-scroll: treat offline as "ready" so the scenario still
      // records the failure mode in the trace instead of timing out silently.
      return true
    case .idle, .connecting:
      return false
    }
  }
}
