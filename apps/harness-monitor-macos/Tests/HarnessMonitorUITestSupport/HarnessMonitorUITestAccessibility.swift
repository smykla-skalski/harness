enum HarnessMonitorUITestAccessibility {
  static let appChromeRoot = "harness.app.chrome"
  static let appChromeState = "harness.app.chrome.state"
  static let auditBuildState = "harness.audit.build.state"
  static let auditBuildBadge = "harness.audit.build.badge"
  static let perfScenarioState = "harness.perf.scenario.state"
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
  static let mcpToolbarStatus = "harness.toolbar.mcp.status"
  static let mcpBanner = "harness.content.mcp.banner"
  static let workspaceToolbarButton = "harness.toolbar.workspace"
  static let workspaceToolbarButtonState = "harness.toolbar.workspace.state"
  static let workspaceToolbarForceTick = "harness.toolbar.workspace.force-tick"
  static let workspaceWindow = "harness.workspace.window"
  static let workspaceDetailAwaitingDecisionState =
    "harness.workspace.detail.awaiting-decision.state"
  static let decisionsSidebar = "harness.decisions.sidebar"
  static let decisionDetail = "harness.decisions.detail"
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
  static let preferencesRoot = "harness.preferences.root"
  static let preferencesState = "harness.preferences.state"
  static let preferencesPanel = "harness.preferences.panel"
  static let preferencesToolbarSeparatorSuppressed =
    "harness.preferences.toolbar.separator-suppressed"
  static let preferencesSidebar = "harness.preferences.sidebar"
  static let preferencesBackButton = "harness.preferences.nav.back"
  static let preferencesForwardButton = "harness.preferences.nav.forward"
  static let preferencesTitle = "harness.preferences.title"
  static let preferencesThemeModePicker = "harness.preferences.theme-mode"
  static let preferencesBackdropModePicker = "harness.preferences.backdrop-mode"
  static let preferencesBackgroundCollectionPicker = "harness.preferences.background-collection"
  static let preferencesBackgroundGallery = "harness.preferences.background-gallery"
  static let preferencesBackgroundRecentsSection = "harness.preferences.background.recents-section"
  static let preferencesBackgroundRecentState = "harness.preferences.background.recents-state"
  static let preferencesTextSizePicker = "harness.preferences.text-size"
  static let preferencesTimeZoneModePicker = "harness.preferences.time-zone-mode"
  static let preferencesCustomTimeZonePicker = "harness.preferences.custom-time-zone"
  static let preferencesGeneralSection = "harness.preferences.section.general"
  static let preferencesAppearanceSection = "harness.preferences.section.appearance"
  static let preferencesNotificationsSection = "harness.preferences.section.notifications"
  static let preferencesSupervisorSection = "harness.preferences.section.supervisor"
  static let preferencesVoiceSection = "harness.preferences.section.voice"
  static let preferencesConnectionSection = "harness.preferences.section.connection"
  static let preferencesDatabaseSection = "harness.preferences.section.database"
  static let preferencesDiagnosticsSection = "harness.preferences.section.diagnostics"
  static let preferencesMCPSection = "harness.preferences.mcp"
  static let preferencesMCPRegistryHostToggle = "harness.preferences.mcp.registry-host"
  static let preferencesMCPStatus = "harness.preferences.mcp.status"
  static let preferencesVoiceRoot = "harness.preferences.voice"
  static let preferencesVoiceLocaleField = "harness.preferences.voice.locale-field"
  static let preferencesVoiceLocalePicker = "harness.preferences.voice.locale-picker"
  static let preferencesVoiceLocalDaemonToggle = "harness.preferences.voice.local-daemon"
  static let preferencesVoiceAgentBridgeToggle = "harness.preferences.voice.agent-bridge"
  static let preferencesVoiceRemoteProcessorToggle = "harness.preferences.voice.remote-processor"
  static let preferencesVoiceRemoteProcessorURLField =
    "harness.preferences.voice.remote-processor-url"
  static let preferencesVoiceInsertionModePicker = "harness.preferences.voice.insertion-mode"
  static let preferencesVoiceAudioChunksToggle = "harness.preferences.voice.audio-chunks"
  static let preferencesVoicePendingAudioField =
    "harness.preferences.voice.pending-audio-limit"
  static let preferencesVoicePendingTranscriptField =
    "harness.preferences.voice.pending-transcript-limit"
  static let preferencesVoiceStatus = "harness.preferences.voice.status"
  static let preferencesNotificationsStatus = "harness.preferences.notifications.status"
  static let preferencesAcpNotificationStatus = "harness.preferences.acp.status"
  static let preferencesAcpNotificationStatusState = "harness.preferences.acp.status.state"
  static let preferencesAcpCatalogToggle = "harness.preferences.acp.catalog.toggle"
  static let preferencesAcpCatalogPermission = "harness.preferences.acp.catalog.permission"
  static let preferencesAcpOpenSystemSettings = "harness.preferences.acp.open-system-settings"
  static let preferencesNotificationsPresetPicker = "harness.preferences.notifications.preset"
  static let preferencesNotificationsCategoryPicker = "harness.preferences.notifications.category"
  static let preferencesNotificationsSoundPicker = "harness.preferences.notifications.sound"
  static let preferencesNotificationsAttachmentPicker =
    "harness.preferences.notifications.attachment"
  static let preferencesNotificationsTriggerPicker = "harness.preferences.notifications.trigger"
  static let preferencesNotificationsSendButton = "harness.preferences.notifications.send"
  static let preferencesAuthorizedFoldersSection = "harness.preferences.section.authorizedfolders"
  static let preferencesAuthorizedFoldersAddButton = "harness.preferences.authorized-folders.add"
  static let preferencesAuthorizedFoldersEmpty = "harness.preferences.authorized-folders.empty"

  static func preferencesAuthorizedFolderRow(_ id: String) -> String {
    "harness.preferences.authorized-folders.row.\(id)"
  }

  static let preferencesDatabaseStatistics = "harness.preferences.database.statistics"
  static let preferencesDatabaseStatisticsPicker =
    "harness.preferences.database.statistics-picker"
  static let preferencesDatabaseOperations = "harness.preferences.database.operations"
  static let preferencesDatabaseHealth = "harness.preferences.database.health"
  static let refreshStatisticsButton = "harness.preferences.action.refresh-statistics"
  static let clearSessionCacheButton = "harness.preferences.action.clear-session-cache"
  static let clearSearchHistoryPrefsButton = "harness.preferences.action.clear-search-history"
  static let clearUserDataButton = "harness.preferences.action.clear-user-data"
  static let clearAllDataButton = "harness.preferences.action.clear-all-data"
  static let revealInFinderButton = "harness.preferences.action.reveal-in-finder"
  static let persistenceMetric = "harness.preferences.metric.persistence"
  static let schemaVersionMetric = "harness.preferences.metric.schema-version"
  static let cachedSessionsMetric = "harness.preferences.metric.cached-sessions"
  static let cachedProjectsMetric = "harness.preferences.metric.cached-projects"
  static let preferencesEndpointCard = "harness.preferences.metric.endpoint"
  static let preferencesVersionCard = "harness.preferences.metric.version"
  static let preferencesLaunchdCard = "harness.preferences.metric.launchd"
  static let preferencesDatabaseSizeCard = "harness.preferences.metric.database-size"
  static let preferencesLiveSessionsCard = "harness.preferences.metric.live-sessions"
  static let reconnectButton = "harness.preferences.action.reconnect"
  static let refreshDiagnosticsButton = "harness.preferences.action.refresh-diagnostics"
  static let startDaemonButton = "harness.preferences.action.start-daemon"
  static let installLaunchAgentButton = "harness.preferences.action.install-launch-agent"
  static let removeLaunchAgentButton = "harness.preferences.action.remove-launch-agent"
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
  static let sidebarNewSessionButton = "harness.sidebar.new-session"
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

  static func preferencesSectionButton(_ key: String) -> String {
    "harness.preferences.section.\(key)"
  }

  static func preferencesSupervisorPane(_ key: String) -> String {
    "harness.preferences.supervisor.\(slug(key))"
  }

  static let preferencesDaemonLogLevelPicker = "harness.preferences.daemon.logLevel"
  static let preferencesSupervisorLogLevelPicker = "harness.preferences.supervisor.logLevel"

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

  static func preferencesBackgroundTile(_ key: String) -> String {
    "harness.preferences.background.\(slug(key))"
  }

  static func preferencesAcpPermissionLogRevealButton(_ runID: String) -> String {
    "harness.preferences.diagnostics.acp-permission-log.reveal.\(slug(runID))"
  }

  static func preferencesAcpPermissionLogError(_ runID: String) -> String {
    "harness.preferences.diagnostics.acp-permission-log.error.\(slug(runID))"
  }

  static func preferencesAcpPermissionLogRevealStatus(_ runID: String) -> String {
    "harness.preferences.diagnostics.acp-permission-log.reveal-status.\(slug(runID))"
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

  static let sessionTaskListHeader = "harness.session.tasks.header"
  static let sessionTaskListHeaderFrame = "\(sessionTaskListHeader).frame"
  static let sessionTaskListState = "harness.session.tasks.state"
  static func agentRowPersonaChip(_ agentID: String) -> String {
    "\(sessionAgentCard(agentID)).persona"
  }

  static func sessionRow(_ sessionID: String) -> String {
    "harness.sidebar.session.\(slug(sessionID))"
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
