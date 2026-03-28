enum MonitorAccessibility {
  static let daemonCard = "monitor.sidebar.daemon-card"
  static let sidebarRoot = "monitor.sidebar.root"
  static let sidebarEmptyState = "monitor.sidebar.empty-state"
  static let sidebarSessionList = "monitor.sidebar.session-list"
  static let sidebarToggleButton = "monitor.toolbar.sidebar-toggle"
  static let sessionFilterGroup = "monitor.sidebar.filter-group"
  static let onboardingCard = "monitor.board.onboarding-card"
  static let sessionsBoardRoot = "monitor.board.root"
  static let recentSessionsCard = "monitor.board.recent-sessions-card"
  static let contentRoot = "monitor.content.root"
  static let inspectorRoot = "monitor.inspector.root"
  static let inspectorEmptyState = "monitor.inspector.empty-state"
  static let sessionInspectorCard = "monitor.inspector.session-card"
  static let observerInspectorCard = "monitor.inspector.observer-card"
  static let preferencesRoot = "monitor.preferences.root"
  static let refreshButton = "monitor.toolbar.refresh"
  static let daemonPreferencesButton = "monitor.toolbar.preferences"

  static func sessionRow(_ sessionID: String) -> String {
    "monitor.sidebar.session.\(sessionID)"
  }

  static func sessionFilterButton(_ filter: String) -> String {
    "monitor.sidebar.filter.\(filter)"
  }
}
