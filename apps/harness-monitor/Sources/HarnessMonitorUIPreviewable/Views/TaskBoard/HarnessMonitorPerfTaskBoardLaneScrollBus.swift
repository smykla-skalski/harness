import Foundation
import HarnessMonitorKit

/// Perf-only bus for nudging the task-board lane scroll surfaces (the inner
/// `ScrollView` inside each `TaskBoardLaneUnifiedColumn`). The live-interact
/// scenario uses this to exercise one column while the rest of the surface
/// stays put.
public enum HarnessMonitorPerfTaskBoardLaneScrollBus {
  public static let scrollToBottom = Notification.Name(
    "io.harnessmonitor.perf.taskBoardLaneScroll.bottom"
  )

  public static let scrollToTop = Notification.Name(
    "io.harnessmonitor.perf.taskBoardLaneScroll.top"
  )

  /// `userInfo[laneRawKey]` carries the `TaskBoardInboxLane.rawValue` so a
  /// driver run can target a single lane without broadcasting to every column.
  public static let laneRawKey = "io.harnessmonitor.perf.taskBoardLaneScroll.lane"

  public static let scenarioEnvironmentKey = "HARNESS_MONITOR_PERF_SCENARIO"

  public static let activeScenarioIDs: Set<String> = [
    "dashboard-live-interact"
  ]

  private static let auditComponent = "perf.task-board-lane-scroll"

  public static func isActive(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    let raw =
      environment[scenarioEnvironmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return activeScenarioIDs.contains(raw)
  }

  /// The environment cannot change after launch, so per-init callers should read this instead of re-bridging it via `isActive()`.
  public static let isActiveAtLaunch: Bool = isActive()

  public static func requestScroll(
    laneRaw: String,
    edge: String
  ) {
    HarnessMonitorPerfTrace.recordScenarioEvent(
      component: auditComponent,
      event: "scroll.request.\(edge)",
      details: ["lane": laneRaw]
    )
    let name = edge == "top" ? scrollToTop : scrollToBottom
    NotificationCenter.default.post(
      name: name,
      object: nil,
      userInfo: [laneRawKey: laneRaw]
    )
  }

  public static func recordAccepted(laneRaw: String, edge: String) {
    HarnessMonitorPerfTrace.recordScenarioEvent(
      component: auditComponent,
      event: "scroll.accepted.\(edge)",
      details: ["lane": laneRaw]
    )
  }
}
