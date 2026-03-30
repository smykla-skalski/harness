enum HarnessAccessibility {
  static let appChromeRoot = "harness.app.chrome"
  static let appChromeState = "harness.app.chrome.state"
  static let daemonCard = "harness.sidebar.daemon-card"
  static let daemonCardFrame = "harness.sidebar.daemon-card.frame"
  static let sidebarRoot = "harness.sidebar.root"
  static let sidebarShellFrame = "harness.sidebar.shell.frame"
  static let sidebarEmptyState = "harness.sidebar.empty-state"
  static let sidebarSessionList = "harness.sidebar.session-list"
  static let sidebarSessionListContent = "harness.sidebar.session-list.content"
  static let sidebarFiltersCard = "harness.sidebar.filters"
  static let sidebarClearFiltersButton = "harness.sidebar.filters.clear"
  static let sessionFilterGroup = "harness.sidebar.filter-group"
  static func sidebarFilterChip(_ filter: String) -> String {
    "harness.sidebar.filter-chip.\(slug(filter))"
  }
  static func sidebarFocusChip(_ filter: String) -> String {
    "harness.sidebar.focus-chip.\(slug(filter))"
  }
  static let onboardingCard = "harness.board.onboarding-card"
  static let sessionsBoardRoot = "harness.board.root"
  static let recentSessionsCard = "harness.board.recent-sessions-card"
  static let contentRoot = "harness.content.root"
  static let inspectorRoot = "harness.inspector.root"
  static let inspectorEmptyState = "harness.inspector.empty-state"
  static let sessionInspectorCard = "harness.inspector.session-card"
  static let taskInspectorCard = "harness.inspector.task-card"
  static let agentInspectorCard = "harness.inspector.agent-card"
  static let signalInspectorCard = "harness.inspector.signal-card"
  static let observerInspectorCard = "harness.inspector.observer-card"
  static let actionActorPicker = "harness.inspector.action-actor"
  static let removeAgentButton = "harness.inspector.remove-agent"
  static let signalSendButton = "harness.inspector.signal-send"
  static let preferencesRoot = "harness.preferences.root"
  static let preferencesState = "harness.preferences.state"
  static let preferencesPanel = "harness.preferences.panel"
  static let preferencesSidebar = "harness.preferences.sidebar"
  static let preferencesBackButton = "harness.preferences.nav.back"
  static let preferencesForwardButton = "harness.preferences.nav.forward"
  static let preferencesTitle = "harness.preferences.title"
  static let preferencesThemeModePicker = "harness.preferences.theme-mode"
  static let preferencesThemeStylePicker = "harness.preferences.theme-style"
  static let refreshButton = "harness.toolbar.refresh"
  static let daemonPreferencesButton = "harness.toolbar.preferences"
  static let endSessionButton = "harness.session.action.end"
  static let pendingLeaderTransferCard = "harness.session.pending-transfer"
  static let sidebarStartDaemonButton = "harness.sidebar.action.start"
  static let sidebarInstallLaunchAgentButton = "harness.sidebar.action.install"
  static let sidebarStartDaemonButtonFrame = "harness.sidebar.action.start.frame"
  static let sidebarInstallLaunchAgentButtonFrame = "harness.sidebar.action.install.frame"
  static let connectionBadge = "harness.toolbar.connection-badge"
  static let transportBadge = "harness.sidebar.transport-badge"
  static let latencyBadge = "harness.sidebar.latency-badge"
  static let activityPulse = "harness.sidebar.activity-pulse"
  static let reconnectionProgress = "harness.sidebar.reconnection-progress"
  static let fallbackBanner = "harness.sidebar.fallback-banner"
  static let connectionCard = "harness.preferences.connection-card"

  static func sessionRow(_ sessionID: String) -> String {
    "harness.sidebar.session.\(sessionID)"
  }

  static func projectHeader(_ projectID: String) -> String {
    "harness.sidebar.project-header.\(slug(projectID))"
  }

  static func projectHeaderFrame(_ projectID: String) -> String {
    "\(projectHeader(projectID)).frame"
  }

  static func sessionFilterButton(_ filter: String) -> String {
    "harness.sidebar.filter.\(filter)"
  }

  static func boardMetricCard(_ key: String) -> String {
    "harness.board.metric.\(slug(key))"
  }

  static func boardMetricGlassState(_ key: String) -> String {
    "harness.board.metric.\(slug(key)).glass-state"
  }

  static let daemonCardGlassState = "harness.sidebar.daemon-card.glass-state"

  static func sidebarDaemonBadge(_ key: String) -> String {
    "harness.sidebar.daemon-badge.\(slug(key))"
  }

  static func sidebarDaemonBadgeFrame(_ key: String) -> String {
    "\(sidebarDaemonBadge(key)).frame"
  }

  static func sessionTaskCard(_ taskID: String) -> String {
    "harness.session.task.\(slug(taskID))"
  }

  static func sessionAgentCard(_ agentID: String) -> String {
    "harness.session.agent.\(slug(agentID))"
  }

  static func preferencesMetricCard(_ key: String) -> String {
    "harness.preferences.metric.\(slug(key))"
  }

  static func preferencesSectionButton(_ key: String) -> String {
    "harness.preferences.section.\(slug(key))"
  }

  static func preferencesActionButton(_ key: String) -> String {
    "harness.preferences.action.\(slug(key))"
  }

  private static func slug(_ value: String) -> String {
    let lowercased = value.lowercased()
    return
      lowercased
      .replacing(" ", with: "-")
      .replacing("_", with: "-")
      .replacing(".", with: "")
  }
}
