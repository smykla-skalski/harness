enum MonitorAccessibility {
  static let daemonCard = "monitor.sidebar.daemon-card"
  static let daemonCardFrame = "monitor.sidebar.daemon-card.frame"
  static let sidebarRoot = "monitor.sidebar.root"
  static let sidebarEmptyState = "monitor.sidebar.empty-state"
  static let sidebarSessionList = "monitor.sidebar.session-list"
  static let sidebarSessionListContent = "monitor.sidebar.session-list.content"
  static let sessionFilterGroup = "monitor.sidebar.filter-group"
  static let onboardingCard = "monitor.board.onboarding-card"
  static let sessionsBoardRoot = "monitor.board.root"
  static let recentSessionsCard = "monitor.board.recent-sessions-card"
  static let contentRoot = "monitor.content.root"
  static let inspectorRoot = "monitor.inspector.root"
  static let inspectorEmptyState = "monitor.inspector.empty-state"
  static let sessionInspectorCard = "monitor.inspector.session-card"
  static let taskInspectorCard = "monitor.inspector.task-card"
  static let agentInspectorCard = "monitor.inspector.agent-card"
  static let signalInspectorCard = "monitor.inspector.signal-card"
  static let observerInspectorCard = "monitor.inspector.observer-card"
  static let actionActorPicker = "monitor.inspector.action-actor"
  static let removeAgentButton = "monitor.inspector.remove-agent"
  static let signalSendButton = "monitor.inspector.signal-send"
  static let preferencesRoot = "monitor.preferences.root"
  static let preferencesBackdrop = "monitor.preferences.backdrop"
  static let preferencesCloseButton = "monitor.preferences.close"
  static let preferencesPanel = "monitor.preferences.panel"
  static let refreshButton = "monitor.toolbar.refresh"
  static let daemonPreferencesButton = "monitor.toolbar.preferences"
  static let endSessionButton = "monitor.session.action.end"
  static let pendingLeaderTransferCard = "monitor.session.pending-transfer"
  static let sidebarStartDaemonButton = "monitor.sidebar.action.start"
  static let sidebarInstallLaunchAgentButton = "monitor.sidebar.action.install"
  static let sidebarStartDaemonButtonFrame = "monitor.sidebar.action.start.frame"
  static let sidebarInstallLaunchAgentButtonFrame = "monitor.sidebar.action.install.frame"
  static let connectionBadge = "monitor.toolbar.connection-badge"
  static let transportBadge = "monitor.sidebar.transport-badge"
  static let latencyBadge = "monitor.sidebar.latency-badge"
  static let activityPulse = "monitor.sidebar.activity-pulse"
  static let reconnectionProgress = "monitor.sidebar.reconnection-progress"
  static let fallbackBanner = "monitor.sidebar.fallback-banner"
  static let connectionCard = "monitor.preferences.connection-card"

  static func sessionRow(_ sessionID: String) -> String {
    "monitor.sidebar.session.\(sessionID)"
  }

  static func projectHeader(_ projectID: String) -> String {
    "monitor.sidebar.project-header.\(slug(projectID))"
  }

  static func projectHeaderFrame(_ projectID: String) -> String {
    "\(projectHeader(projectID)).frame"
  }

  static func sessionFilterButton(_ filter: String) -> String {
    "monitor.sidebar.filter.\(filter)"
  }

  static func boardMetricCard(_ key: String) -> String {
    "monitor.board.metric.\(slug(key))"
  }

  static func sidebarDaemonBadge(_ key: String) -> String {
    "monitor.sidebar.daemon-badge.\(slug(key))"
  }

  static func sidebarDaemonBadgeFrame(_ key: String) -> String {
    "\(sidebarDaemonBadge(key)).frame"
  }

  static func sessionTaskCard(_ taskID: String) -> String {
    "monitor.session.task.\(slug(taskID))"
  }

  static func sessionAgentCard(_ agentID: String) -> String {
    "monitor.session.agent.\(slug(agentID))"
  }

  static func preferencesMetricCard(_ key: String) -> String {
    "monitor.preferences.metric.\(slug(key))"
  }

  static func preferencesActionButton(_ key: String) -> String {
    "monitor.preferences.action.\(slug(key))"
  }

  private static func slug(_ value: String) -> String {
    let lowercased = value.lowercased()
    return
      lowercased
      .replacingOccurrences(of: " ", with: "-")
      .replacingOccurrences(of: "_", with: "-")
      .replacingOccurrences(of: ".", with: "")
  }
}
