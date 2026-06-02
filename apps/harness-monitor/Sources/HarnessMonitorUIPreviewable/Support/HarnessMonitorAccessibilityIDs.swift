import SwiftUI

public enum HarnessMonitorAccessibility {
  public static let appChromeRoot = "harness.app.chrome"
  public static let appChromeState = "harness.app.chrome.state"
  public static let auditBuildState = "harness.audit.build.state"
  public static let auditBuildBadge = "harness.audit.build.badge"
  public static let perfScenarioState = "harness.perf.scenario.state"
  public static func windowShellState(_ windowID: String) -> String {
    "harness.window.\(slug(windowID)).shell.state"
  }

  public static func windowBannerChrome(_ windowID: String) -> String {
    "harness.window.\(slug(windowID)).banner-chrome"
  }

  public static func windowBannerChromeState(_ windowID: String) -> String {
    "\(windowBannerChrome(windowID)).state"
  }

  public static let toolbarChromeState = "harness.toolbar.chrome.state"
  public static let toolbarBaselineDivider = "harness.toolbar.baseline-divider"
  public static let persistenceBanner = "harness.persistence.banner"
  public static let persistedDataBanner = "harness.persisted-data.banner"
  public static let daemonWireVersionSkewBanner = "harness.daemon.wire-version-skew.banner"
  public static let persistedDataBannerFrame = "\(persistedDataBanner).frame"
  public static let sessionStatusCorner = "harness.session-status.corner"
  public static let sessionStatusCornerFrame = "\(sessionStatusCorner).frame"
  public static let sidebarRoot = "harness.sidebar.root"
  public static let sidebarShellFrame = "harness.sidebar.shell.frame"
  public static let sidebarEmptyState = "harness.sidebar.empty-state"
  public static let sidebarEmptyStateFrame = "\(sidebarEmptyState).frame"
  public static let sidebarSessionList = "harness.sidebar.session-list"
  public static let sidebarSessionListContent = "harness.sidebar.session-list.content"
  public static let sidebarTrailingWhitespaceClearArea =
    "harness.sidebar.trailing-whitespace-clear-area"
  public static let sidebarTrailingWhitespaceClearAreaFrame =
    "\(sidebarTrailingWhitespaceClearArea).frame"
  public static let sidebarSessionListState = "harness.sidebar.session-list.state"
  public static let sidebarFiltersCard = "harness.sidebar.filters"
  public static let sidebarFiltersCardFrame = "\(sidebarFiltersCard).frame"
  public static let sidebarCreateMenuButton = "harness.sidebar.create-menu"
  public static let sidebarCreateMenuButtonFrame = "\(sidebarCreateMenuButton).frame"
  public static let sidebarCreateMenuNewAgentItem = "harness.sidebar.create-menu.new-agent"
  public static let sidebarCreateMenuNewTaskItem = "harness.sidebar.create-menu.new-task"
  public static let sidebarFilterState = "harness.sidebar.filter.state"
  public static let sidebarSearchState = "harness.sidebar.search.state"
  public static let sidebarSearchField = "harness.sidebar.search"
  public static let sidebarClearFiltersButton = "harness.sidebar.filters.clear"
  public static let sidebarClearSearchHistoryButton = "harness.sidebar.search.clear-history"
  public static let sessionFilterGroup = "harness.sidebar.filter-group"
  public static let sidebarStatusPicker = "harness.sidebar.picker.status"
  public static let sidebarSortPicker = "harness.sidebar.picker.sort"
  public static let sidebarFocusPicker = "harness.sidebar.picker.focus"

  public static func sidebarFilterChip(_ filter: String) -> String {
    "harness.sidebar.filter-chip.\(slug(filter))"
  }

  public static func sidebarFocusChip(_ filter: String) -> String {
    "harness.sidebar.focus-chip.\(slug(filter))"
  }

  public static func sidebarSortSegment(_ order: String) -> String {
    "harness.sidebar.sort.\(slug(order))"
  }

  public static func openRecentSessionRow(_ sessionID: String) -> String {
    "harness.open.recent.session.\(slug(sessionID))"
  }

  public static func sessionWindowRoute(_ route: SessionWindowRoute) -> String {
    "harness.session.window.route.\(slug(route.rawValue))"
  }

  public static func dashboardWindowRoute(_ route: String) -> String {
    "harness.dashboard.route.\(slug(dashboardWindowRouteAlias(route)))"
  }

  private static func dashboardWindowRouteAlias(_ route: String) -> String {
    // The Dependencies route was renamed to Reviews in the 2026-05-22 rename
    // project. The route enum still uses `.dependencies` as its raw value so
    // any caller (SwiftUI route case, persisted SceneStorage, MCP target) can
    // address it by either name, but the public accessibility identifier
    // tracks the user-visible name `reviews`.
    let lowered = route.lowercased()
    if lowered == "dependencies" { return "reviews" }
    return route
  }

  public static func sessionWindowAgentRow(_ agentID: String) -> String {
    "harness.session.window.agents.row.\(slug(agentID))"
  }

  public static func sessionWindowTaskRow(_ taskID: String) -> String {
    "harness.session.window.tasks.row.\(slug(taskID))"
  }

  public static let dashboardWindowRoot = "harness.dashboard.window"
  public static let dashboardToolbarSeparatorSuppressed =
    "harness.dashboard.window.toolbar.separator-suppressed"
  public static let dashboardSidebar = "harness.dashboard.sidebar"
  public static let dashboardScrollView = "harness.dashboard.scroll"
  public static let dashboardAuditRoot = "harness.dashboard.audit"
  public static let dashboardAuditDetailDivider =
    "harness.dashboard.audit.content-detail-divider"
  public static let dashboardAuditScrollView = "harness.dashboard.audit.scroll"
  public static let dashboardAuditEmptyState = "harness.dashboard.audit.empty-state"
  public static let dashboardNotificationsRoot = "harness.dashboard.notifications"
  public static let dashboardNotificationsScrollView = "harness.dashboard.notifications.scroll"
  public static let dashboardNotificationsEmptyState = "harness.dashboard.notifications.empty-state"
  public static let dashboardReviewsModeSwitcher =
    "harness.dashboard.reviews.mode-switcher"
  public static let dashboardReviewsOverviewModeButton =
    "harness.dashboard.reviews.mode.overview"
  public static let dashboardReviewsFilesModeButton =
    "harness.dashboard.reviews.mode.files"
  public static let dashboardReviewFilesHeader =
    "harness.dashboard.reviews.files.header"
  public static let dashboardReviewFilesFilterField =
    "harness.dashboard.reviews.files.filter"
  public static let dashboardReviewFilesMoreButton =
    "harness.dashboard.reviews.files.more"
  public static let dashboardReviewFilesFiltersMoreButton =
    "harness.dashboard.reviews.files.filters-more"
  public static let dashboardReviewFilesSortMenu =
    "harness.dashboard.reviews.files.sort"
  public static let dashboardReviewFilesViewModePicker =
    "harness.dashboard.reviews.files.view-mode"
  public static let dashboardReviewFilesSoftWrapToggle =
    "harness.dashboard.reviews.files.soft-wrap"
  public static let dashboardReviewFilesTree =
    "harness.dashboard.reviews.files.tree"
  public static func dashboardReviewFileCard(path: String) -> String {
    "harness.dashboard.reviews.files.card.\(slug(path))"
  }

  public static func dashboardReviewFileViewedToggle(path: String) -> String {
    "harness.dashboard.reviews.files.viewed-toggle.\(slug(path))"
  }

  public static let dashboardNewSessionButton = "harness.dashboard.new-session"
  public static let dashboardOpenFolderButton = "harness.dashboard.open-folder"
  public static let sessionsBoardRoot = "harness.board.root"
  public static let sessionsBoardScrollView = "harness.board.scroll"
  public static let openRecentRoot = "harness.open.recent"
  public static let openRecentProjectList = "harness.open.recent.projects"
  public static let openRecentOpenFolderButton = "harness.open.recent.open-folder"
  public static let openRecentNewSessionButton = "harness.open.recent.new-session"
  public static let openRecentActionState = "harness.open.recent.action-state"
  public static let sessionWindowShell = "harness.session.window"
  public static let sessionWindowSidebar = "harness.session.window.sidebar"
  public static let sessionWindowSidebarDeferredLoader =
    "harness.session.window.sidebar.loader"
  public static let sessionWindowContentDetailDivider =
    "harness.session.window.content-detail-divider"
  public static let sessionWindowStatusSurface = "harness.session.window.status"
  public static let sessionWindowToolbarSeparatorSuppressed =
    "harness.session.window.toolbar.separator-suppressed"
  public static let sessionWindowFocusModeButton = "harness.session.window.toolbar.focus-mode"
  public static let sessionWindowCreateProviderPane =
    "harness.session.window.create.provider-pane"
  public static let sessionWindowInspector = "harness.session.window.inspector"
  public static let sessionWindowInspectorCloseButton =
    "harness.session.window.inspector.close"
  public static let sessionWindowDismissUndoToast =
    "harness.session.window.decisions.dismiss-undo-toast"
  public static let sessionWindowSidebarSelectionState =
    "harness.session.window.sidebar.selection-state"
  public static let contentRoot = "harness.content.root"
  public static let navigateBackButton = "harness.toolbar.navigate-back"
  public static let navigateForwardButton = "harness.toolbar.navigate-forward"
  public static let sessionNavigateBackButton = "harness.session.window.toolbar.navigate-back"
  public static let sessionNavigateForwardButton = "harness.session.window.toolbar.navigate-forward"
  public static let refreshButton = "harness.toolbar.refresh"
  public static let daemonSettingsButton = "harness.toolbar.settings"
  public static let sleepPreventionButton = "harness.toolbar.sleep-prevention"
  public static let mcpBanner = "harness.content.mcp.banner"
  public static let menuBarExtra = "harness.menu-bar.extra"
  public static let menuBarConnectionStatus = "harness.menu-bar.status.connection"
  public static let menuBarSessionStatus = "harness.menu-bar.status.sessions"
  public static let menuBarDecisionStatus = "harness.menu-bar.status.decisions"
  public static let menuBarSupervisorStatus = "harness.menu-bar.status.supervisor"
  public static let menuBarOpenMonitor = "harness.menu-bar.action.open-monitor"
  public static let menuBarOpenSession = "harness.menu-bar.action.open-session"
  public static let menuBarOpenSettings = "harness.menu-bar.action.open-settings"
  public static let menuBarRefresh = "harness.menu-bar.action.refresh"
  public static let menuBarSupervisorToggle = "harness.menu-bar.action.supervisor-toggle"
  public static let menuBarSupervisorCheckNow = "harness.menu-bar.action.supervisor-check-now"
  public static let menuBarRunWhenClosed = "harness.menu-bar.action.run-when-closed"
  public static let menuBarQuit = "harness.menu-bar.action.quit"
  public static let windowMenuMainItem = "harness.menu.window.main"
  public static let sessionHeaderCard = "harness.session.header"
  public static let sessionHeaderCardFrame = "\(sessionHeaderCard).frame"
  public static let sessionAgentListHeader = "harness.session.agents.header"
  public static let sessionAgentListHeaderFrame = "\(sessionAgentListHeader).frame"
  public static let sessionTaskListHeader = "harness.session.tasks.header"
  public static let sessionTaskListHeaderFrame = "\(sessionTaskListHeader).frame"
  public static let sessionHeaderLeaderActivity = "harness.session.header.leader-activity"
  public static let observeSessionButton = "harness.session.action.observe"
  public static let sendSignalButton = "harness.session.action.send-signal"
  public static let endSessionButton = "harness.session.action.end"
  public static let pendingLeaderTransferCard = "harness.session.pending-transfer"
  public static let connectionBadge = "harness.toolbar.connection-badge"
  public static let transportBadge = "harness.sidebar.transport-badge"
  public static let latencyBadge = "harness.sidebar.latency-badge"
  public static let activityPulse = "harness.sidebar.activity-pulse"
  public static let reconnectionProgress = "harness.sidebar.reconnection-progress"
  public static let actionToast = "harness.action-toast"
  public static let actionToastFrame = "harness.action-toast.frame"
  public static let actionToastCloseButton = "harness.action-toast.close"
  public static let actionToastUndoButton = "harness.action-toast.undo"
  public static let actionToastPrimaryButton = "harness.action-toast.primary"
  public static let actionToastDetailsButton = "harness.action-toast.details"
  public static let actionToastCommandCopyButton = "harness.action-toast.command.copy"
  public static let sessionTimelinePagination = "harness.session.timeline.pagination"
  public static let sessionTimelinePageSizePicker =
    "harness.session.timeline.pagination.page-size"
  public static let sessionTimelinePaginationPrevious =
    "harness.session.timeline.pagination.previous"
  public static let sessionTimelinePaginationNext = "harness.session.timeline.pagination.next"
  public static let sessionTimelinePaginationStatus =
    "harness.session.timeline.pagination.status"
  public static let sessionTimelineNavigation = "harness.session.timeline.navigation"
  public static let sessionTimelineNavigationStatus =
    "harness.session.timeline.navigation.status"
  public static let sessionTimelineVisibleStatus =
    "harness.session.timeline.navigation.visible-status"
  public static let sessionTimelineFilterBar = "harness.session.timeline.filters"
  public static let sessionTimelineFilterScopeMenu = "harness.session.timeline.filters.scope"
  public static let sessionTimelineFilterMoreButton = "harness.session.timeline.filters.more"
  public static let sessionTimelineFilterClearButton = "harness.session.timeline.filters.clear"
  public static let sessionTimelineFilterState = "harness.session.timeline.filters.state"
  public static let sessionTimelineFilterSignalsPreset =
    "harness.session.timeline.filters.signals-preset"
  public static let sessionTimelineOlderButton = "harness.session.timeline.navigation.older"
  public static let sessionTimelineLatestButton = "harness.session.timeline.navigation.latest"
  public static let sessionTimelineNewerButton = "harness.session.timeline.navigation.newer"
  public static let connectionCard = "harness.settings.connection-card"
  public static let agentTuiButton = "harness.session.agent-tui"
  public static let agentDetailScrollView = "harness.agent.detail.scroll"
  public static let sessionTaskDetailScrollView = "harness.session.task.detail.scroll"
  public static let agentTuiSheet = "harness.sheet.agent-tui"
  public static let agentTuiState = "harness.sheet.agent-tui.state"
  public static let agentTuiCommandRoutingState = "harness.sheet.agent-tui.command-routing"
  public static let agentTuiCreateTab = "harness.sheet.agent-tui.tab.create"
  public static let agentTuiCreateModePicker = "harness.sheet.agent-tui.create-mode"
  public static let agentTuiRuntimePicker = "harness.sheet.agent-tui.runtime"
  public static let agentTuiRolePicker = "harness.sheet.agent-tui.role"
  public static let agentTuiFallbackRolePicker = "harness.agent.role-fallback"
  public static let agentTuiNameField = "harness.sheet.agent-tui.name"
  public static let agentTuiNameSuggestButton = "harness.sheet.agent-tui.name.suggest"
  public static let agentTuiPromptField = "harness.sheet.agent-tui.prompt"
  public static let agentTuiProjectDirField = "harness.sheet.agent-tui.project-dir"
  public static let agentTuiArgvField = "harness.sheet.agent-tui.argv"
  public static let agentTuiLaunchPane = "harness.sheet.agent-tui.launch-pane"
  public static let agentTuiSessionPane = "harness.sheet.agent-tui.session-pane"
  public static let agentTuiViewport = "harness.sheet.agent-tui.viewport"
  public static let agentTuiInputField = "harness.sheet.agent-tui.input"
  public static let agentTuiInputModePicker = "harness.sheet.agent-tui.input-mode"
  public static let agentTuiKeyQueueHint = "harness.sheet.agent-tui.key-queue"
  public static let agentTuiSubmitWithEnterToggle = "harness.sheet.agent-tui.submit-with-enter"
  public static let agentTuiRefreshButton = "harness.sheet.agent-tui.refresh"
  public static let agentTuiStartButton = "harness.sheet.agent-tui.start"
  public static let agentTuiSendButton = "harness.sheet.agent-tui.send"
  public static let agentTuiResizeButton = "harness.sheet.agent-tui.resize"
  public static let agentTuiStopButton = "harness.sheet.agent-tui.stop"
  public static let agentTuiRevealTranscriptButton = "harness.sheet.agent-tui.transcript"
  public static let agentTuiRecoveryBanner = "harness.sheet.agent-tui.recovery-banner"
  public static let agentTuiSessionActionBanner = "harness.sheet.agent-tui.session-action-banner"
  public static let agentTuiPendingUserPrompt = "harness.sheet.agent-tui.pending-user-prompt"
  public static let agentTuiEnableBridgeButton = "harness.sheet.agent-tui.enable-bridge"
  public static let agentTuiNewSessionButton = "harness.sheet.agent-tui.new-session"
  public static let agentTuiCopyCommandButton = "harness.sheet.agent-tui.copy-command"
  public static let agentTuiBackToCreateButton = "harness.sheet.agent-tui.back-to-create"
  public static let agentTuiWrapToggle = "harness.sheet.agent-tui.wrap-toggle"
  public static let agentTuiNavigateBackButton = "harness.sheet.agent-tui.navigate-back"
  public static let agentTuiNavigateForwardButton = "harness.sheet.agent-tui.navigate-forward"
  public static let newSessionSheet = "harness.new-session.sheet"
  public static let newCodexAgentSheet = "harness.new-codex-agent.sheet"
  public static let openRouterModelBrowserSheet = "harness.openrouter-model-browser.sheet"
  public static let openRouterModelBrowserSearch = "harness.openrouter-model-browser.search"
  public static let openRouterModelBrowserList = "harness.openrouter-model-browser.list"
  public static let sessionOpenRouterRunRow = "harness.session.openrouter-run-row"
  public static let sessionOpenRouterRunDetail = "harness.session.openrouter-run-detail"
  public static let sessionOpenRouterRunPromptField =
    "harness.session.openrouter-run.prompt-field"
  public static let sessionOpenRouterRunSendButton =
    "harness.session.openrouter-run.send-button"
  public static let sessionOpenRouterRunCancelButton =
    "harness.session.openrouter-run.cancel-button"
  public static let newSessionTitle = "harness.new-session.title"
  public static let newSessionContext = "harness.new-session.context"
  public static let newSessionBaseRef = "harness.new-session.base-ref"
  public static let newSessionProjectPicker = "harness.new-session.project-picker"
  public static let newSessionTabPicker = "harness.new-session.tab-picker"
  public static let newSessionCreateTab = "harness.new-session.tab.create.control"
  public static let newSessionRuntimeTab = "harness.new-session.tab.runtime.control"
  public static let newSessionCreatePanel = "harness.new-session.tab.create.panel"
  public static let newSessionRuntimePanel = "harness.new-session.tab.runtime.panel"
  public static let newSessionCreateDisabledReason = "harness.new-session.create-disabled-reason"
  public static let newSessionCreateButton = "harness.new-session.create-button"
  public static let newSessionCancelButton = "harness.new-session.cancel-button"
  public static let newSessionErrorBanner = "harness.new-session.error-banner"
  public static let sendSignalSheet = "harness.sheet.send-signal"
  public static let sendSignalSheetCommandField = "harness.sheet.send-signal.command"
  public static let sendSignalSheetMessageField = "harness.sheet.send-signal.message"
  public static let sendSignalSheetMessageVoiceButton = "harness.sheet.send-signal.message.voice"
  public static let sendSignalSheetActionHintField = "harness.sheet.send-signal.action-hint"
  public static let sendSignalSheetCancelButton = "harness.sheet.send-signal.cancel"
  public static let sendSignalSheetSubmitButton = "harness.sheet.send-signal.submit"
  public static let settingsCodexSection = "harness.settings.codex"
  public static let settingsAgentsSection = settingsCodexSection
  public static let settingsPoliciesCanvasThemePicker =
    "harness.settings.policies.canvas-theme"
  public static let settingsPoliciesEdgeLegendToggle =
    "harness.settings.policies.edge-legend"
  public static let settingsPoliciesMinimapToggle =
    "harness.settings.policies.minimap"
  public static let settingsPoliciesMinimapCenteringPicker =
    "harness.settings.policies.minimap-centering"
  public static let settingsPoliciesAutosaveIntervalPicker =
    "harness.settings.policies.autosave-interval"
  public static let settingsPoliciesClipboardToggle =
    "harness.settings.policies.clipboard-monitor"
  public static let settingsPoliciesWorkflowStatusToggle =
    "harness.settings.policies.workflow-status"
  public static let settingsCodexCopyStartButton = "harness.settings.codex.copy-start"
  public static let settingsCodexCopyInstallButton = "harness.settings.codex.copy-install"
  public static let settingsAgentsCopyStartButton = settingsCodexCopyStartButton
  public static let settingsAgentsCopyInstallButton = settingsCodexCopyInstallButton
  public static let settingsDatabaseStatistics = "harness.settings.database.statistics"
  public static let settingsDatabaseStatisticsPicker =
    "harness.settings.database.statistics-picker"
  public static let settingsDatabaseOperations = "harness.settings.database.operations"
  public static let settingsDatabaseHealth = "harness.settings.database.health"
  public static let settingsAuthorizedFoldersAddButton =
    "harness.settings.authorized-folders.add"
  public static let settingsAuthorizedFoldersUnavailable =
    "harness.settings.authorized-folders.unavailable"
  public static let settingsAuthorizedFoldersEmpty =
    "harness.settings.authorized-folders.empty"
}
