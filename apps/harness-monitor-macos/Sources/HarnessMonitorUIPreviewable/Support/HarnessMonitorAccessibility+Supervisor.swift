import Foundation

extension HarnessMonitorAccessibility {
  public static let supervisorBadge = "harness.supervisor.badge"
  public static let supervisorBadgeState = "harness.supervisor.badge.state"
  public static let supervisorForceTick = "harness.supervisor.force-tick"
  public static let decisionsWindow = "harness.decisions.window"
  public static let decisionsSidebar = "harness.decisions.sidebar"
  public static let decisionDetail = "harness.decisions.detail"
  public static let decisionDetailTabs = "harness.decisions.detail.tabs"
  public static let decisionContextPanel = "harness.decisions.context"
  public static let decisionAuditTrail = "harness.decisions.audit"
  public static let decisionsLiveTick = "harness.decisions.live-tick"
  public static let decisionInspector = "harness.decisions.inspector"
  public static let decisionInspectorMetadata = "harness.decisions.inspector.metadata"
  public static let decisionInspectorToggle = "harness.decisions.inspector.toggle"
  public static let decisionBulkActions = "harness.decisions.bulk-actions"
  public static let decisionBulkSnoozeCritical = "harness.decisions.bulk-actions.snooze-critical"
  public static let decisionBulkDismissInfo = "harness.decisions.bulk-actions.dismiss-info"
  public static let decisionsObserverPanel = "harness.decisions.observer.panel"
  public static let decisionsObserverEmptyState = "harness.decisions.observer.empty-state"

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
