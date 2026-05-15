import Foundation
import HarnessMonitorKit

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

  private static let auditComponent = "perf.dashboard-live-scroll"

  public static func isActive(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    environment[scenarioEnvironmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      == activeScenarioID
  }

  /// Route scroll-trigger events through the shared perf trace bus so the audit
  /// JSONL records them alongside the driver-side scroll.post events. Without
  /// this, the os_signpost trace still gets the data but the extractor's app-trace
  /// summary stays at 0 for view-side signals.
  public static func recordTrigger(edge: String) {
    HarnessMonitorPerfTrace.recordScenarioEvent(
      component: auditComponent,
      event: "scroll.trigger.\(edge)"
    )
  }

  /// Same routing for geometry-change offset samples. The audit extractor can
  /// compare trigger events against the offset events to confirm the scroll
  /// surface really moved.
  public static func recordOffset(_ y: CGFloat) {
    HarnessMonitorPerfTrace.recordScenarioEvent(
      component: auditComponent,
      event: "scroll.offset",
      details: ["y": String(Int(y.rounded()))]
    )
  }
}
