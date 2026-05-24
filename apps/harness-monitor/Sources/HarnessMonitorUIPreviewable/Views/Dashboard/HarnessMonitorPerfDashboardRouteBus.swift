import Foundation
import HarnessMonitorKit

/// Perf-only bus used by `HarnessMonitorPerfDriver` to ask the live dashboard
/// window to programmatically switch its sidebar route (e.g. task-board ->
/// policy-canvas and back). Mirrors `HarnessMonitorPerfDashboardScrollBus`:
/// inert in non-perf builds, scenario-gated via `HARNESS_MONITOR_PERF_SCENARIO`.
public enum HarnessMonitorPerfDashboardRouteBus {
  /// Posted by the driver with a route raw value in `userInfo[routeRawKey]`.
  public static let routeChange = Notification.Name(
    "io.harnessmonitor.perf.dashboardRoute.change"
  )

  public static let routeRawKey = "io.harnessmonitor.perf.dashboardRoute.raw"

  public static let scenarioEnvironmentKey = "HARNESS_MONITOR_PERF_SCENARIO"

  /// Scenarios that need the route hook wired. Other live scenarios that want
  /// the same affordance can append their identifier here.
  public static let activeScenarioIDs: Set<String> = [
    "dashboard-live-interact"
  ]

  private static let auditComponent = "perf.dashboard-live-interact"

  public static func isActive(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    let raw =
      environment[scenarioEnvironmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return activeScenarioIDs.contains(raw)
  }

  /// Post a route-change request. The view layer translates the raw value back
  /// into its private enum; an unknown raw value is a no-op.
  public static func requestRoute(raw: String) {
    HarnessMonitorPerfTrace.recordScenarioEvent(
      component: auditComponent,
      event: "route.request",
      details: ["raw": raw]
    )
    NotificationCenter.default.post(
      name: routeChange,
      object: nil,
      userInfo: [routeRawKey: raw]
    )
  }

  /// Record that the view layer accepted a route switch. Called by
  /// `DashboardWindowView` after it commits the new selection.
  public static func recordAccepted(raw: String) {
    HarnessMonitorPerfTrace.recordScenarioEvent(
      component: auditComponent,
      event: "route.accepted",
      details: ["raw": raw]
    )
  }
}
