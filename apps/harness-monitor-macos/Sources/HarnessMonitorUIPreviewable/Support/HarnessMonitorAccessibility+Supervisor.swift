import Foundation

extension HarnessMonitorAccessibility {
  public static let supervisorBadge = "harness.supervisor.badge"
  public static let decisionsWindow = "harness.decisions.window"
  public static let decisionsSidebar = "harness.decisions.sidebar"
  public static let decisionDetail = "harness.decisions.detail"
  public static let decisionContextPanel = "harness.decisions.context"
  public static let decisionAuditTrail = "harness.decisions.audit"
  public static let decisionsLiveTick = "harness.decisions.live-tick"

  public static func decisionRow(_ id: String) -> String {
    "harness.decisions.row.\(slug(id))"
  }

  public static func decisionAction(_ id: String) -> String {
    "harness.decisions.action.\(slug(id))"
  }

  public static func preferencesSupervisorPane(_ key: String) -> String {
    "harness.preferences.supervisor.\(slug(key))"
  }
}
