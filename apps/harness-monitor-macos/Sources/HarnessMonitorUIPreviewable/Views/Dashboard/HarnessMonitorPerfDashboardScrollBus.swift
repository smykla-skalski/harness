import Foundation

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
}
