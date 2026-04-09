import SwiftUI

enum HarnessMonitorAccessibility {
  static let appChromeRoot = "harness.app.chrome"
  static let appChromeState = "harness.app.chrome.state"
  static let auditBuildState = "harness.audit.build.state"
  static let toolbarChromeState = "harness.toolbar.chrome.state"
  static let toolbarBaselineDivider = "harness.toolbar.baseline-divider"
  static let persistenceBanner = "harness.persistence.banner"
  static let persistedDataBanner = "harness.persisted-data.banner"
  static let persistedDataBannerFrame = "\(persistedDataBanner).frame"
  static let sessionStatusBanner = "harness.session-status.banner"
  static let sidebarRoot = "harness.sidebar.root"
  static let sidebarShellFrame = "harness.sidebar.shell.frame"
  static let sidebarEmptyState = "harness.sidebar.empty-state"
  static let sidebarEmptyStateFrame = "\(sidebarEmptyState).frame"
  static let sidebarSessionList = "harness.sidebar.session-list"
  static let sidebarSessionListContent = "harness.sidebar.session-list.content"
  static let sidebarFiltersCard = "harness.sidebar.filters"
  static let sidebarFiltersCardFrame = "\(sidebarFiltersCard).frame"
  static let sidebarFilterMenu = "harness.toolbar.sidebar-filters"
  static let sidebarFilterState = "harness.sidebar.filter.state"
  static let sidebarFiltersToggle = sidebarFilterMenu
  static let sidebarSearchField = "harness.sidebar.search"
  static let sidebarClearFiltersButton = "harness.sidebar.filters.clear"
  static let sidebarClearSearchHistoryButton = "harness.sidebar.search.clear-history"
  static let sessionFilterGroup = "harness.sidebar.filter-group"
  static let sidebarSortPicker = "harness.sidebar.picker.sort"
  static let sidebarFocusPicker = "harness.sidebar.picker.focus"

  static func sidebarFilterChip(_ filter: String) -> String {
    "harness.sidebar.filter-chip.\(slug(filter))"
  }

  static func sidebarFocusChip(_ filter: String) -> String {
    "harness.sidebar.focus-chip.\(slug(filter))"
  }

  static func sidebarSortSegment(_ order: String) -> String {
    "harness.sidebar.sort.\(slug(order))"
  }

  static let onboardingCard = "harness.board.onboarding-card"
  static let onboardingStartButton = "harness.board.action.start"
  static let onboardingInstallButton = "harness.board.action.install"
  static let onboardingRefreshButton = "harness.board.action.refresh"
  static let onboardingStartButtonFrame = "harness.board.action.start.frame"
  static let onboardingInstallButtonFrame = "harness.board.action.install.frame"
  static let onboardingRefreshButtonFrame = "harness.board.action.refresh.frame"
  static let onboardingDismissButton = "harness.board.onboarding-card.dismiss"
  static let sessionsBoardRoot = "harness.board.root"
  static let recentSessionsCard = "harness.board.recent-sessions-card"
  static let contentRoot = "harness.content.root"
  static let inspectorRoot = "harness.inspector.root"
  static let inspectorEmptyState = "harness.inspector.empty-state"
  static let inspectorLoadingState = "harness.inspector.loading-state"
  static let sessionInspectorCard = "harness.inspector.session-card"
  static let taskInspectorCard = "harness.inspector.task-card"
  static let taskNoteField = "harness.inspector.task-note-field"
  static let taskNoteAddButton = "harness.inspector.task-note-add"
  static let taskNotesUnavailable = "harness.inspector.task-notes-unavailable"
  static let agentInspectorCard = "harness.inspector.agent-card"
  static let signalInspectorCard = "harness.inspector.signal-card"
  static let observerInspectorCard = "harness.inspector.observer-card"
  static let actionActorPicker = "harness.inspector.action-actor"
  static let signalCommandField = "harness.inspector.signal-command"
  static let signalMessageField = "harness.inspector.signal-message"
  static let removeAgentButton = "harness.inspector.remove-agent"
  static let signalSendButton = "harness.inspector.signal-send"
  static let leaderTransferSection = "harness.inspector.leader-transfer"
  static let leaderTransferPicker = "harness.inspector.leader-transfer-picker"
  static let preferencesRoot = "harness.preferences.root"
  static let preferencesState = "harness.preferences.state"
  static let preferencesPanel = "harness.preferences.panel"
  static let preferencesSidebar = "harness.preferences.sidebar"
  static let preferencesBackButton = "harness.preferences.nav.back"
  static let preferencesForwardButton = "harness.preferences.nav.forward"
  static let preferencesTitle = "harness.preferences.title"
  static let preferencesThemeModePicker = "harness.preferences.theme-mode"
  static let preferencesBackdropModePicker = "harness.preferences.backdrop-mode"
  static let preferencesBackgroundGallery = "harness.preferences.background-gallery"
  static let preferencesTextSizePicker = "harness.preferences.text-size"
  static let preferencesTimeZoneModePicker = "harness.preferences.time-zone-mode"
  static let preferencesCustomTimeZonePicker = "harness.preferences.custom-time-zone"
  static let navigateBackButton = "harness.toolbar.navigate-back"
  static let navigateForwardButton = "harness.toolbar.navigate-forward"
  static let toolbarCenterpiece = "harness.toolbar.centerpiece"
  static let toolbarCenterpieceFrame = "harness.toolbar.centerpiece.frame"
  static let toolbarCenterpieceState = "harness.toolbar.centerpiece.state"
  static let toolbarCenterpieceMode = "harness.toolbar.centerpiece.mode"
  static let toolbarCenterpieceMetricsFrame = "harness.toolbar.centerpiece.metrics.frame"
  static let toolbarStartDaemonButton = "harness.toolbar.action.start"
  static let toolbarStatusTicker = "harness.toolbar.status-ticker"
  static let toolbarStatusTickerFrame = "harness.toolbar.status-ticker.frame"
  static let toolbarStatusTickerContentFrame = "harness.toolbar.status-ticker.content.frame"
  static let toolbarStatusTickerHoverFrame = "harness.toolbar.status-ticker.hover.frame"
  static let refreshButton = "harness.toolbar.refresh"
  static let daemonPreferencesButton = "harness.toolbar.preferences"
  static let inspectorToggleButton = "harness.toolbar.inspector-toggle"
  static let sleepPreventionButton = "harness.toolbar.sleep-prevention"
  static let endSessionButton = "harness.session.action.end"
  static let pendingLeaderTransferCard = "harness.session.pending-transfer"
  static let connectionBadge = "harness.toolbar.connection-badge"
  static let transportBadge = "harness.sidebar.transport-badge"
  static let latencyBadge = "harness.sidebar.latency-badge"
  static let activityPulse = "harness.sidebar.activity-pulse"
  static let reconnectionProgress = "harness.sidebar.reconnection-progress"
  static let actionToast = "harness.action-toast"
  static let sessionTimelinePagination = "harness.session.timeline.pagination"
  static let sessionTimelinePageSizePicker = "harness.session.timeline.pagination.page-size"
  static let sessionTimelinePaginationPrevious = "harness.session.timeline.pagination.previous"
  static let sessionTimelinePaginationNext = "harness.session.timeline.pagination.next"
  static let sessionTimelinePaginationStatus = "harness.session.timeline.pagination.status"
  static let connectionCard = "harness.preferences.connection-card"
  static let cornerOverlay = "harness.corner-overlay"
  static let sendSignalSheet = "harness.sheet.send-signal"
  static let sendSignalSheetCommandField = "harness.sheet.send-signal.command"
  static let sendSignalSheetMessageField = "harness.sheet.send-signal.message"
  static let sendSignalSheetActionHintField = "harness.sheet.send-signal.action-hint"
  static let sendSignalSheetCancelButton = "harness.sheet.send-signal.cancel"
  static let sendSignalSheetSubmitButton = "harness.sheet.send-signal.submit"
  static let preferencesDatabaseStatistics = "harness.preferences.database.statistics"
  static let preferencesDatabaseOperations = "harness.preferences.database.operations"
  static let preferencesDatabaseHealth = "harness.preferences.database.health"

  static func sessionRow(_ sessionID: String) -> String {
    "harness.sidebar.session.\(sessionID)"
  }

  static func sessionRowFrame(_ sessionID: String) -> String {
    "\(sessionRow(sessionID)).frame"
  }

  static func projectHeader(_ projectID: String) -> String {
    "harness.sidebar.project-header.\(slug(projectID))"
  }

  static func projectHeaderFrame(_ projectID: String) -> String {
    "\(projectHeader(projectID)).frame"
  }

  static func worktreeHeader(_ checkoutID: String) -> String {
    "harness.sidebar.worktree-header.\(slug(checkoutID))"
  }

  static func worktreeHeaderFrame(_ checkoutID: String) -> String {
    "\(worktreeHeader(checkoutID)).frame"
  }

  static func sessionFilterButton(_ filter: String) -> String {
    "harness.sidebar.filter.\(filter)"
  }

  static func sessionTaskCard(_ taskID: String) -> String {
    "harness.session.task.\(slug(taskID))"
  }

  static func sessionAgentCard(_ agentID: String) -> String {
    "harness.session.agent.\(slug(agentID))"
  }

  static func sessionAgentSignalTrigger(_ agentID: String) -> String {
    "harness.session.agent.\(slug(agentID)).signal-trigger"
  }

  static func sessionSignalCard(_ signalID: String) -> String {
    "harness.session.signal.\(slug(signalID))"
  }

  static func sessionTimelinePaginationPageButton(_ pageNumber: Int) -> String {
    "harness.session.timeline.pagination.page.\(pageNumber)"
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

  static func preferencesBackgroundTile(_ key: String) -> String {
    "harness.preferences.background.\(slug(key))"
  }

  private static func slug(_ value: String) -> String {
    let lowercased = value.lowercased()
    return
      lowercased
      .replacing(" ", with: "-")
      .replacing("_", with: "-")
      .replacing(":", with: "-")
      .replacing("/", with: "-")
      .replacing(".", with: "")
  }
}
