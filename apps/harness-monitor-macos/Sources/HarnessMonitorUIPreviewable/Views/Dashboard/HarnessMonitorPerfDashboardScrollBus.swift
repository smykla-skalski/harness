import Foundation
import OSLog

/// Perf-only bus used by `HarnessMonitorPerfDriver` to ask the live dashboard window
/// to programmatically scroll. The dashboard view listens for these notifications
/// when it detects an active perf scenario via the `HARNESS_MONITOR_PERF_SCENARIO`
/// environment variable. The bus stays inert in non-perf builds because nothing
/// posts to it.
public enum HarnessMonitorPerfDashboardScrollBus {
  /// Posted when the perf driver wants the dashboard's main scroll surface to scroll
  /// to its bottom edge.
  public static let scrollToBottom = Notification.Name(
    "io.harnessmonitor.perf.dashboardScroll.bottom"
  )

  /// Posted when the perf driver wants the dashboard's main scroll surface to scroll
  /// back to its top edge.
  public static let scrollToTop = Notification.Name(
    "io.harnessmonitor.perf.dashboardScroll.top"
  )

  /// Environment variable inspected by the dashboard view to decide whether to wire
  /// the scroll-position binding. Outside of perf runs the binding stays nil so the
  /// shared `HarnessMonitorColumnScrollView` keeps its default behavior.
  public static let scenarioEnvironmentKey = "HARNESS_MONITOR_PERF_SCENARIO"

  /// Scenario identifier this hook listens for. Other live scenarios that need the
  /// same scroll affordance can be added here when introduced.
  public static let activeScenarioID = "dashboard-live-scroll"

  public static func isActive(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    environment[scenarioEnvironmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      == activeScenarioID
  }

  /// Signposter used by the scroll trigger and the geometry observer so an audit
  /// trace can prove the scroll path was exercised. Lives in the same subsystem and
  /// category as the rest of the perf scenario signposts so the existing extractor
  /// picks them up.
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )

  /// Emit a scroll-trigger signpost. Called from the dashboard route view when the
  /// scroll notification arrives so we can confirm `ScrollPosition.scrollTo(edge:)`
  /// was invoked.
  public static func recordTrigger(edge: String) {
    signposter.emitEvent(
      "perf_event",
      "component=perf.dashboard-live-scroll event=scroll.trigger.\(edge)"
    )
  }

  /// Emit an offset signpost. Called from the ScrollView's
  /// `.onScrollGeometryChange` so the trace records every time the actual scroll
  /// position moves. An audit can compare trigger events against offset events to
  /// confirm the scroll surface really moved.
  public static func recordOffset(_ y: CGFloat) {
    signposter.emitEvent(
      "perf_event",
      "component=perf.dashboard-live-scroll event=scroll.offset y=\(Int(y.rounded()))"
    )
  }
}
