enum HarnessMonitorUITestAccessibility {
  static let appChromeRoot = "harness.app.chrome"
  static let appChromeState = "harness.app.chrome.state"
  static let auditBuildState = "harness.audit.build.state"
  static let auditBuildBadge = "harness.audit.build.badge"
  static let perfScenarioState = "harness.perf.scenario.state"
  static func windowShellState(_ windowID: String) -> String {
    "harness.window.\(slug(windowID)).shell.state"
  }

  static func windowBannerChrome(_ windowID: String) -> String {
    "harness.window.\(slug(windowID)).banner-chrome"
  }

  static func windowBannerChromeState(_ windowID: String) -> String {
    "\(windowBannerChrome(windowID)).state"
  }

  static let toolbarChromeState = "harness.toolbar.chrome.state"
  static let toolbarBaselineDivider = "harness.toolbar.baseline-divider"
  static let persistenceBanner = "harness.persistence.banner"
  static let persistedDataBanner = "harness.persisted-data.banner"
  static let persistedDataBannerFrame = "harness.persisted-data.banner.frame"
  static let sessionStatusCorner = "harness.session-status.corner"
  static let sessionStatusCornerFrame = "harness.session-status.corner.frame"
  static let sidebarShellFrame = "harness.sidebar.shell.frame"
  static let navigateBackButton = "harness.toolbar.navigate-back"
  static let navigateForwardButton = "harness.toolbar.navigate-forward"
  static let refreshButton = "harness.toolbar.refresh"
  static let sleepPreventionButton = "harness.toolbar.sleep-prevention"
  static let mcpBanner = "harness.content.mcp.banner"
  static let menuBarExtra = "harness.menu-bar.extra"
  static let menuBarConnectionStatus = "harness.menu-bar.status.connection"
  static let menuBarSessionStatus = "harness.menu-bar.status.sessions"
  static let menuBarDecisionStatus = "harness.menu-bar.status.decisions"
  static let menuBarSupervisorStatus = "harness.menu-bar.status.supervisor"
  static let menuBarOpenMonitor = "harness.menu-bar.action.open-monitor"
  static let menuBarOpenWorkspace = "harness.menu-bar.action.open-workspace"
  static let menuBarOpenSettings = "harness.menu-bar.action.open-settings"
  static let menuBarRefresh = "harness.menu-bar.action.refresh"
  static let menuBarSupervisorToggle = "harness.menu-bar.action.supervisor-toggle"
  static let menuBarSupervisorCheckNow = "harness.menu-bar.action.supervisor-check-now"
  static let menuBarRunWhenClosed = "harness.menu-bar.action.run-when-closed"
  static let menuBarQuit = "harness.menu-bar.action.quit"
  static let workspaceToolbarButton = "harness.toolbar.workspace"
  static let workspaceToolbarButtonState = "harness.toolbar.workspace.state"
  static let workspaceToolbarForceTick = "harness.toolbar.workspace.force-tick"
  static let workspaceWindow = "harness.workspace.window"
  static let workspaceDetailAwaitingDecisionState =
    "harness.workspace.detail.awaiting-decision.state"
  static let decisionsSidebar = "harness.decisions.sidebar"
  static let decisionDetail = "harness.decisions.detail"
  static let decisionDetailScrollView = "harness.decisions.detail.scroll"
  static let decisionPrimaryActionFocusState = "harness.decisions.primary-action.focus"
  static let decisionDetailTabs = "harness.decisions.detail.tabs"
  static let decisionAuditTrail = "harness.decisions.audit"
  static let decisionInspector = "harness.decisions.inspector"
  static let decisionInspectorMetadata = "harness.decisions.inspector.metadata"
  static let decisionInspectorToggle = "harness.decisions.inspector.toggle"
  static let decisionBulkActions = "harness.decisions.bulk-actions"
  static let decisionBulkSnoozeCritical = "harness.decisions.bulk-actions.snooze-critical"
  static let decisionBulkDismissInfo = "harness.decisions.bulk-actions.dismiss-info"
  static let decisionBulkDismissSelected = "harness.decisions.bulk-actions.dismiss-selected"
  static let decisionBulkDismissVisible = "harness.decisions.bulk-actions.dismiss-visible"
  static let decisionBulkDismissVisibleInput =
    "harness.decisions.bulk-actions.dismiss-visible.input"
  static let decisionBulkDismissVisibleConfirm =
    "harness.decisions.bulk-actions.dismiss-visible.confirm"
  static let decisionBulkDismissVisibleCancel =
    "harness.decisions.bulk-actions.dismiss-visible.cancel"
  static let decisionBulkReopenBatch = "harness.decisions.bulk-actions.reopen-batch"
  static let decisionsObserverPanel = "harness.decisions.observer.panel"
  static let decisionsObserverEmptyState = "harness.decisions.observer.empty-state"
  static func decisionRow(_ id: String) -> String {
    "harness.decisions.row.\(slug(id))"
  }
  static func decisionAction(_ id: String) -> String {
    "harness.decisions.action.\(slug(id))"
  }
  static let sessionHeaderCard = "harness.session.header"
  static let sessionHeaderCardFrame = "harness.session.header.frame"
  static let sidebarRoot = "harness.sidebar.root"
  static let sidebarFooter = "harness.sidebar.footer"
  static let sidebarFooterState = "harness.sidebar.footer.state"
  static let previewProjectHeader = "harness.sidebar.project-header.project-6ccf8d0a"
  static let previewProjectHeaderFrame = "harness.sidebar.project-header.project-6ccf8d0a.frame"
  static let previewCheckoutHeader = "harness.sidebar.worktree-header.sess1234"
  static let previewCheckoutHeaderFrame = "harness.sidebar.worktree-header.sess1234.frame"
  static let previewCheckoutHeaderGlyph = "harness.sidebar.worktree-header.sess1234.glyph"
  static let previewSessionRow = "harness.sidebar.session.sess1234"
  static let previewSessionRowFrame = "harness.sidebar.session.sess1234.frame"
  static let previewSessionRowSelectionFrame =
    "harness.sidebar.session.sess1234.selection.frame"
  static let previewSessionRowAgentStat = "harness.sidebar.session.sess1234.stat.agent"
  static let previewSessionRowTaskStat = "harness.sidebar.session.sess1234.stat.task"
  static let previewSessionRowStatsFrame = "harness.sidebar.session.sess1234.stats.frame"
  static let previewSessionRowLastActivityFrame =
    "harness.sidebar.session.sess1234.last-activity.frame"
  static let sessionWindowContentDetailDivider =
    "harness.session.window.content-detail-divider"
  static let signalRegressionSecondarySessionRow = "harness.sidebar.session.sess-harness-secondary"
  static let previewSignalCard = "harness.session.signal.sig-ui-1"
  static let singleAgentSessionRow = "harness.sidebar.session.sess-harness-solo"
  static let overflowSessionRow = "harness.sidebar.session.sess-harness-17"
  static let previewSessionTitle =
    "Track all live multi-agent harness sessions from a macOS cockpit"
  static let sidebarEmptyState = "harness.sidebar.empty-state"
  static let sidebarEmptyStateFrame = "harness.sidebar.empty-state.frame"
  static let sidebarEmptyStateTitle = "No sessions indexed yet"
  static let sidebarSessionList = "harness.sidebar.session-list"
  static let sidebarSessionListContent = "harness.sidebar.session-list.content"
  static let sidebarTrailingWhitespaceClearArea = "harness.sidebar.trailing-whitespace-clear-area"
  static let sidebarTrailingWhitespaceClearAreaFrame =
    "harness.sidebar.trailing-whitespace-clear-area.frame"
  static let sidebarSessionListState = "harness.sidebar.session-list.state"
  static let sidebarFiltersCard = "harness.sidebar.filters"
  static let sidebarFiltersCardFrame = "harness.sidebar.filters.frame"
  static let sidebarFilterState = "harness.sidebar.filter.state"
  static let sidebarSearchState = "harness.sidebar.search.state"
  static let sessionFilterGroup = "harness.sidebar.filter-group"
  static let sidebarStatusPicker = "harness.sidebar.picker.status"
  static let sidebarSearchField = "harness.sidebar.search"
  static let sidebarClearFiltersButton = "harness.sidebar.filters.clear"
  static let sidebarClearSearchHistoryButton = "harness.sidebar.search.clear-history"
  static let sidebarSortPicker = "harness.sidebar.picker.sort"
  static let sidebarFocusPicker = "harness.sidebar.picker.focus"
  static let activeFilterButton = "harness.sidebar.filter.active"
  static let allFilterButton = "harness.sidebar.filter.all"
  static let endedFilterButton = "harness.sidebar.filter.ended"
  static let openWorkChip = "harness.sidebar.focus-chip.openwork"
  static let blockedChip = "harness.sidebar.focus-chip.blocked"
  static let observedChip = "harness.sidebar.focus-chip.observed"
  static let idleChip = "harness.sidebar.focus-chip.idle"
  static let sessionsBoardRoot = "harness.board.root"
  static let sessionsBoardScrollView = "harness.board.scroll"
  static let recentSessionsCard = "harness.board.recent-sessions-card"
  static let recentSessionsCardFrame = "harness.board.recent-sessions-card.frame"
  static let contentRoot = "harness.content.root"
  static let contentRootFrame = "harness.content.root.frame"
  static let contentAcpBridgeBanner = "harness.content.acp-bridge.banner"
  static let contentAcpBridgeOpenLogButton = "harness.content.acp-bridge.open-log"
  static let contentAcpBridgeRunDoctorButton = "harness.content.acp-bridge.run-doctor"
  static let observeSummaryButton = "harness.session.observe.summary"
  static let observeSessionButton = "harness.session.action.observe"
  static let endSessionButton = "harness.session.action.end"
  static let pendingLeaderTransferCard = "harness.session.pending-transfer"
  static let taskDropQueueCard = "harness.session.task.task-drop-queue"
  static let taskUICard = "harness.session.task.task-ui"
  static let taskRoutingCard = "harness.session.task.task-routing"
  static let leaderAgentCard = "harness.session.agent.leader-claude"
  static let workerAgentCard = "harness.session.agent.worker-codex"
  static let settingsRoot = "harness.settings.root"
  static let settingsState = "harness.settings.state"
  static let settingsPanel = "harness.settings.panel"
  static let settingsToolbarSeparatorSuppressed =
    "harness.settings.toolbar.separator-suppressed"
  static let settingsSidebar = "harness.settings.sidebar"
  static let settingsBackButton = "harness.settings.nav.back"
  static let settingsForwardButton = "harness.settings.nav.forward"
  static let settingsTitle = "harness.settings.title"
  static let settingsThemeModePicker = "harness.settings.theme-mode"
  static let settingsBackdropModePicker = "harness.settings.backdrop-mode"
  static let settingsBackgroundCollectionPicker = "harness.settings.background-collection"
  static let settingsBackgroundGallery = "harness.settings.background-gallery"
  static let settingsBackgroundRecentsSection = "harness.settings.background.recents-section"
  static let settingsBackgroundRecentState = "harness.settings.background.recents-state"
  static let settingsTextSizePicker = "harness.settings.text-size"
  static let settingsMenuBarStateColorsToggle =
    "harness.settings.menu-bar.state-colors"
  static let settingsSessionRowModePicker =
    "harness.settings.sidebar-session-row-mode"
  static let settingsTimeZoneModePicker = "harness.settings.time-zone-mode"
  static let settingsCustomTimeZonePicker = "harness.settings.custom-time-zone"
  static let settingsPendingDecisionBannersToggle =
    "harness.settings.decisions.pending-banners"
  static let settingsPendingDecisionBannersFocusModeToggle =
    "harness.settings.decisions.pending-banners.focus-mode"
  static let settingsGeneralSection = "harness.settings.section.general"
  static let settingsAppearanceSection = "harness.settings.section.appearance"
  static let settingsNotificationsSection = "harness.settings.section.notifications"
  static let settingsSupervisorSection = "harness.settings.section.supervisor"
  static let settingsVoiceSection = "harness.settings.section.voice"
  static let settingsConnectionSection = "harness.settings.section.connection"
  static let settingsDatabaseSection = "harness.settings.section.database"
  static let settingsDiagnosticsSection = "harness.settings.section.diagnostics"
  static let settingsMCPSection = "harness.settings.mcp"
  static let settingsMCPRegistryHostToggle = "harness.settings.mcp.registry-host"
  static let settingsMCPStatus = "harness.settings.mcp.status"
  static let settingsVoiceRoot = "harness.settings.voice"
  static let settingsVoiceLocaleField = "harness.settings.voice.locale-field"
  static let settingsVoiceLocalePicker = "harness.settings.voice.locale-picker"
  static let settingsVoiceLocalDaemonToggle = "harness.settings.voice.local-daemon"
  static let settingsVoiceAgentBridgeToggle = "harness.settings.voice.agent-bridge"
  static let settingsVoiceRemoteProcessorToggle = "harness.settings.voice.remote-processor"
  static let settingsVoiceRemoteProcessorURLField =
    "harness.settings.voice.remote-processor-url"
  static let settingsVoiceInsertionModePicker = "harness.settings.voice.insertion-mode"
  static let settingsVoiceAudioChunksToggle = "harness.settings.voice.audio-chunks"
  static let settingsVoicePendingAudioField =
    "harness.settings.voice.pending-audio-limit"
  static let settingsVoicePendingTranscriptField =
    "harness.settings.voice.pending-transcript-limit"
  static let settingsVoiceStatus = "harness.settings.voice.status"
  static let settingsNotificationsStatus = "harness.settings.notifications.status"
  static let settingsAcpNotificationStatus = "harness.settings.acp.status"
  static let settingsAcpNotificationStatusState = "harness.settings.acp.status.state"
  static let settingsAcpCatalogToggle = "harness.settings.acp.catalog.toggle"
  static let settingsAcpCatalogPermission = "harness.settings.acp.catalog.permission"
  static let settingsAcpOpenSystemSettings = "harness.settings.acp.open-system-settings"
  static let settingsNotificationsPresetPicker = "harness.settings.notifications.preset"
  static let settingsNotificationsCategoryPicker = "harness.settings.notifications.category"
  static let settingsNotificationsSoundPicker = "harness.settings.notifications.sound"
  static let settingsNotificationsAttachmentPicker =
    "harness.settings.notifications.attachment"
  static let settingsNotificationsTriggerPicker = "harness.settings.notifications.trigger"
  static let settingsNotificationsSendButton = "harness.settings.notifications.send"
  static let settingsAuthorizedFoldersSection = "harness.settings.section.authorizedfolders"
  static let settingsAuthorizedFoldersAddButton = "harness.settings.authorized-folders.add"
  static let settingsAuthorizedFoldersEmpty = "harness.settings.authorized-folders.empty"

  static func settingsAuthorizedFolderRow(_ id: String) -> String {
    "harness.settings.authorized-folders.row.\(id)"
  }

  static let settingsDatabaseStatistics = "harness.settings.database.statistics"
  static let settingsDatabaseStatisticsPicker =
    "harness.settings.database.statistics-picker"
  static let settingsDatabaseOperations = "harness.settings.database.operations"
  static let settingsDatabaseHealth = "harness.settings.database.health"
  static let refreshStatisticsButton = "harness.settings.action.refresh-statistics"
  static let clearSessionCacheButton = "harness.settings.action.clear-session-cache"
  static let clearSearchHistoryPrefsButton = "harness.settings.action.clear-search-history"
  static let clearUserDataButton = "harness.settings.action.clear-user-data"
  static let clearAllDataButton = "harness.settings.action.clear-all-data"
  static let revealInFinderButton = "harness.settings.action.reveal-in-finder"
  static let persistenceMetric = "harness.settings.metric.persistence"
  static let schemaVersionMetric = "harness.settings.metric.schema-version"
  static let cachedSessionsMetric = "harness.settings.metric.cached-sessions"
  static let cachedProjectsMetric = "harness.settings.metric.cached-projects"
  static let settingsEndpointCard = "harness.settings.metric.endpoint"
  static let settingsVersionCard = "harness.settings.metric.version"
  static let settingsLaunchdCard = "harness.settings.metric.launchd"
  static let settingsDatabaseSizeCard = "harness.settings.metric.database-size"
  static let settingsLiveSessionsCard = "harness.settings.metric.live-sessions"
  static let reconnectButton = "harness.settings.action.reconnect"
  static let refreshDiagnosticsButton = "harness.settings.action.refresh-diagnostics"
  static let startDaemonButton = "harness.settings.action.start-daemon"
  static let installLaunchAgentButton = "harness.settings.action.install-launch-agent"
  static let removeLaunchAgentButton = "harness.settings.action.remove-launch-agent"
  static let actionToast = "harness.action-toast"
  static let actionToastFrame = "harness.action-toast.frame"
  static let actionToastCloseButton = "harness.action-toast.close"
  static let acpPermissionToast = "harness.acp-permission.toast"
  static let acpPermissionToastFrame = "harness.acp-permission.toast.frame"
  static let acpPermissionToastState = "harness.acp-permission.toast.state"
  static let acpPermissionToastAccessibilityState =
    "harness.acp-permission.toast.accessibility.state"
  static let toolCallTimelineAccessibilityState =
    "harness.window.workspace.tool-call-timeline.accessibility.state"
  static let agentRuntimeWatchdogAccessibilityState =
    "harness.workspace.detail.runtime.watchdog.accessibility.state"
  static let acpPermissionToastRouteState = "harness.acp-permission.toast.route.state"
  static let acpPermissionToastActionButton = "harness.acp-permission.toast.open-workspace"
  static let acpPermissionToastCloseButton = "harness.acp-permission.toast.close"
  static let sessionTimelinePagination = "harness.session.timeline.pagination"
  static let sessionTimelinePageSizePicker = "harness.session.timeline.pagination.page-size"
  static let sessionTimelinePaginationPrevious = "harness.session.timeline.pagination.previous"
  static let sessionTimelinePaginationNext = "harness.session.timeline.pagination.next"
  static let sessionTimelinePaginationStatus = "harness.session.timeline.pagination.status"
  static let sessionTimelineNavigation = "harness.session.timeline.navigation"
  static let sessionTimelineNavigationStatus = "harness.session.timeline.navigation.status"
  static let sessionTimelineVisibleStatus = "harness.session.timeline.navigation.visible-status"
  static let sessionTimelineOlderButton = "harness.session.timeline.navigation.older"
  static let sessionTimelineLatestButton = "harness.session.timeline.navigation.latest"
  static let sessionTimelineNewerButton = "harness.session.timeline.navigation.newer"
  static let sendSignalSheet = "harness.sheet.send-signal"
  static let sendSignalSheetCommandField = "harness.sheet.send-signal.command"
  static let sendSignalSheetMessageField = "harness.sheet.send-signal.message"
  static let sendSignalSheetMessageVoiceButton = "harness.sheet.send-signal.message.voice"
  static let sendSignalSheetActionHintField = "harness.sheet.send-signal.action-hint"
  static let sendSignalSheetCancelButton = "harness.sheet.send-signal.cancel"
  static let sendSignalSheetSubmitButton = "harness.sheet.send-signal.submit"
  static let sidebarCreateMenuButton = "harness.sidebar.create-menu"
  static let sidebarCreateMenuButtonFrame = "\(sidebarCreateMenuButton).frame"
  static let sidebarCreateMenuNewAgentItem = "harness.sidebar.create-menu.new-agent"
  static let sidebarCreateMenuNewTaskItem = "harness.sidebar.create-menu.new-task"
  static let voiceInputPopover = "harness.voice-input.popover"
  static let voiceInputTranscript = "harness.voice-input.transcript"
  static let voiceInputInsertButton = "harness.voice-input.insert"
  static let voiceInputStopButton = "harness.voice-input.stop"
  static let voiceInputFailureOverlay = "harness.voice-input.failure"
  static let voiceInputFailureMessage = "harness.voice-input.failure.message"
  static let voiceInputFailureInstructions = "harness.voice-input.failure.instructions"
  static let leaderAgentSignalTrigger = "harness.session.agent.leader-claude.signal-trigger"

  static func sessionEmptyState(_ section: String) -> String {
    "harness.session.empty-state.\(slug(section))"
  }

  static func settingsSectionButton(_ key: String) -> String {
    "harness.settings.section.\(key)"
  }

  static func settingsSupervisorPane(_ key: String) -> String {
    "harness.settings.supervisor.\(slug(key))"
  }

  static let settingsDaemonLogLevelPicker = "harness.settings.daemon.logLevel"
  static let settingsSupervisorLogLevelPicker = "harness.settings.supervisor.logLevel"

  static func sessionTimelinePaginationPageButton(_ pageNumber: Int) -> String {
    "harness.session.timeline.pagination.page.\(pageNumber)"
  }

  static func sessionTimelineNode(_ key: String) -> String {
    "harness.session.timeline.node.\(slug(key))"
  }

  static func sessionTimelineActionButton(decisionID: String, actionID: String) -> String {
    "harness.session.timeline.action.\(slug(decisionID)).\(slug(actionID))"
  }

  static func projectHeader(_ projectID: String) -> String {
    "harness.sidebar.project-header.\(slug(projectID))"
  }

  static func worktreeHeader(_ checkoutID: String) -> String {
    "harness.sidebar.worktree-header.\(slug(checkoutID))"
  }

  static func settingsBackgroundTile(_ key: String) -> String {
    "harness.settings.background.\(slug(key))"
  }

  static func settingsAcpPermissionLogRevealButton(_ runID: String) -> String {
    "harness.settings.diagnostics.acp-permission-log.reveal.\(slug(runID))"
  }

  static func settingsAcpPermissionLogError(_ runID: String) -> String {
    "harness.settings.diagnostics.acp-permission-log.error.\(slug(runID))"
  }

  static func settingsAcpPermissionLogRevealStatus(_ runID: String) -> String {
    "harness.settings.diagnostics.acp-permission-log.reveal-status.\(slug(runID))"
  }

  static func sidebarSortSegment(_ order: String) -> String {
    "harness.sidebar.sort.\(slug(order))"
  }

  static func sidebarFocusChip(_ filter: String) -> String {
    "harness.sidebar.focus-chip.\(slug(filter))"
  }

  static let leaderAgentTuiMarker = "harness.session.agent.leader-claude.tui-marker"
  static let workerAgentTuiMarker = "harness.session.agent.worker-codex.tui-marker"
  static let sessionCockpitScrollView = "harness.session.cockpit.scroll"
  static let sessionAgentListState = "harness.session.agents.state"

  static func sessionAgentTuiMarker(_ agentID: String) -> String {
    "harness.session.agent.\(slug(agentID)).tui-marker"
  }

  static func sessionAgentTaskDropFeedback(_ agentID: String) -> String {
    "harness.session.agent.\(slug(agentID)).task-drop-feedback"
  }

  static func sessionAgentCard(_ agentID: String) -> String {
    "harness.session.agent.\(slug(agentID))"
  }

  static func sessionTaskCard(_ taskID: String) -> String {
    "harness.session.task.\(slug(taskID))"
  }

  static let sessionAgentListHeader = "harness.session.agents.header"
  static let sessionAgentListHeaderFrame = "\(sessionAgentListHeader).frame"
  static let sessionTaskListHeader = "harness.session.tasks.header"
  static let sessionTaskListHeaderFrame = "\(sessionTaskListHeader).frame"
  static let sessionTaskListState = "harness.session.tasks.state"
  static func agentRowPersonaChip(_ agentID: String) -> String {
    "\(sessionAgentCard(agentID)).persona"
  }

  static func sessionRow(_ sessionID: String) -> String {
    "harness.sidebar.session.\(slug(sessionID))"
  }

  static func dashboardSessionCard(_ sessionID: String) -> String {
    "harness.board.session.\(slug(sessionID))"
  }

  static func dashboardSessionCardFrame(_ sessionID: String) -> String {
    "\(dashboardSessionCard(sessionID)).frame"
  }

  static func slug(_ value: String) -> String {
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
