import Foundation
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

@MainActor
extension HarnessMonitorPerfDriver {
  /// Drives the dashboard window against the real external daemon and scrolls the
  /// task-board route up and down so an Instruments SwiftUI audit can see the
  /// stutters that show up on the live surface. Requires
  /// `HARNESS_MONITOR_LAUNCH_MODE=live` plus a reachable daemon.
  static func runDashboardLiveScrollScenario(
    store: HarnessMonitorStore
  ) async -> ScenarioResult {
    let launchMode = HarnessMonitorLaunchMode(environment: ProcessInfo.processInfo.environment)
    guard launchMode == .live else {
      HarnessMonitorLogger.store.error(
        "dashboard-live-scroll scenario requires HARNESS_MONITOR_LAUNCH_MODE=live"
      )
      return .failed("launch-mode-not-live")
    }

    await store.bootstrapIfNeeded()
    guard await waitForLiveDashboardReady(store: store) else {
      HarnessMonitorPerfTrace.recordScenarioEvent(
        component: "perf.dashboard-live-scroll",
        event: "wait.timeout",
        details: [
          "connection_state": String(describing: store.connectionState),
          "recent_session_count": String(store.recentSessions.count),
        ]
      )
      return .failed("daemon-not-ready")
    }

    HarnessMonitorPerfTrace.recordScenarioEvent(
      component: "perf.dashboard-live-scroll",
      event: "ready",
      details: [
        "connection_state": String(describing: store.connectionState),
        "recent_session_count": String(store.recentSessions.count),
      ]
    )

    // First settle so first-frame work clears before the scroll begins, otherwise
    // the audit captures cold-start churn instead of the scroll path.
    await settle(.milliseconds(900))

    postScrollEvent(.bottom, pass: 1)
    await settle(.milliseconds(1_400))

    postScrollEvent(.top, pass: 1)
    await settle(.milliseconds(1_000))

    // Second pass exercises the steady-state scroll once the cache is warm. The
    // audit window stays inside `signposter.beginAnimationInterval` so SwiftUI's
    // High-severity update / Hitch events get pinned to this scenario interval.
    postScrollEvent(.bottom, pass: 2)
    await settle(.milliseconds(1_400))

    return .completed
  }

  private enum LiveScrollDirection: String {
    case top
    case bottom
  }

  private static func postScrollEvent(
    _ direction: LiveScrollDirection,
    pass: Int
  ) {
    HarnessMonitorPerfTrace.recordScenarioEvent(
      component: "perf.dashboard-live-scroll",
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

  private static func waitForLiveDashboardReady(
    store: HarnessMonitorStore
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(8))
    while !isLiveDashboardReady(store: store) {
      guard clock.now < deadline else {
        return false
      }
      try? await Task.sleep(for: shortDelay)
    }
    return true
  }

  private static func isLiveDashboardReady(
    store: HarnessMonitorStore
  ) -> Bool {
    switch store.connectionState {
    case .online:
      return true
    case .offline:
      // Treat offline as "ready" so the scenario still records — surfaces the
      // failure mode in the trace instead of timing out invisibly.
      return true
    case .idle, .connecting:
      return false
    }
  }
}
