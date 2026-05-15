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

    // The daemon streams the task-board inbox + supervisor decisions + recent
    // sessions over the first few seconds. If we scroll before that data lands
    // the content is shorter than the 928pt viewport and scrollTo(edge:.bottom)
    // is a documented no-op. Wait at least 4s here so the surface is real-life
    // scrollable. The bus emits scroll.geometry events that prove the size.
    await settle(.milliseconds(4_000))

    postScrollEvent(.bottom, pass: 1)
    await settle(.milliseconds(1_500))

    postScrollEvent(.top, pass: 1)
    await settle(.milliseconds(1_200))

    postScrollEvent(.bottom, pass: 2)
    await settle(.milliseconds(1_500))

    postScrollEvent(.top, pass: 2)
    await settle(.milliseconds(1_200))

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
