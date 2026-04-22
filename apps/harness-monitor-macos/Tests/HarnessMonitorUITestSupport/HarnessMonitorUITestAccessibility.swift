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
  static let inspectorToggleButton = "harness.toolbar.inspector-toggle"
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
  static let contentRootFrame = "harness.content.root.frame"
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
  static let createTaskTitleField = "harness.inspector.create-task.title"
  static let createTaskButton = "harness.inspector.create-task"
  static let assignTaskButton = "harness.inspector.assign-task"
  static let updateTaskQueuePolicyButton = "harness.inspector.update-task-queue-policy"
  static let updateTaskStatusButton = "harness.inspector.update-task-status"
  static let checkpointTaskButton = "harness.inspector.checkpoint-task"
  static let changeRoleButton = "harness.inspector.change-role"
  static let removeAgentButton = "harness.inspector.remove-agent"
  static let signalSendButton = "harness.inspector.signal-send"
  static let leaderTransferSection = "harness.inspector.leader-transfer"
  static let leaderTransferPicker = "harness.inspector.leader-transfer-picker"
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
  static let preferencesVoiceSection = "harness.preferences.section.voice"
  static let preferencesConnectionSection = "harness.preferences.section.connection"
  static let preferencesDatabaseSection = "harness.preferences.section.database"
  static let preferencesDiagnosticsSection = "harness.preferences.section.diagnostics"
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
  static let sessionTimelinePagination = "harness.session.timeline.pagination"
  static let sessionTimelinePageSizePicker = "harness.session.timeline.pagination.page-size"
  static let sessionTimelinePaginationPrevious = "harness.session.timeline.pagination.previous"
  static let sessionTimelinePaginationNext = "harness.session.timeline.pagination.next"
  static let sessionTimelinePaginationStatus = "harness.session.timeline.pagination.status"
  static let sendSignalSheet = "harness.sheet.send-signal"
  static let sendSignalSheetCommandField = "harness.sheet.send-signal.command"
  static let sendSignalSheetMessageField = "harness.sheet.send-signal.message"
  static let sendSignalSheetMessageVoiceButton = "harness.sheet.send-signal.message.voice"
  static let sendSignalSheetActionHintField = "harness.sheet.send-signal.action-hint"
  static let sendSignalSheetCancelButton = "harness.sheet.send-signal.cancel"
  static let sendSignalSheetSubmitButton = "harness.sheet.send-signal.submit"
  static let sidebarNewSessionButton = "harness.sidebar.new-session"
  static let newSessionSheet = "harness.new-session.sheet"
  static let newSessionTitle = "harness.new-session.title"
  static let newSessionContext = "harness.new-session.context"
  static let newSessionBaseRef = "harness.new-session.base-ref"
  static let newSessionProjectPicker = "harness.new-session.project-picker"
  static let newSessionCreateButton = "harness.new-session.create-button"
  static let newSessionCancelButton = "harness.new-session.cancel-button"
  static let newSessionErrorBanner = "harness.new-session.error-banner"
  static let voiceInputPopover = "harness.voice-input.popover"
  static let voiceInputTranscript = "harness.voice-input.transcript"
  static let voiceInputInsertButton = "harness.voice-input.insert"
  static let voiceInputStopButton = "harness.voice-input.stop"
  static let voiceInputFailureOverlay = "harness.voice-input.failure"
  static let voiceInputFailureMessage = "harness.voice-input.failure.message"
  static let voiceInputFailureInstructions = "harness.voice-input.failure.instructions"
  static let leaderAgentSignalTrigger = "harness.session.agent.leader-claude.signal-trigger"
  static let agentsButton = "harness.session.agents"
  static let agentTuiButton = "harness.session.agent-tui"
  static let agentTuiSheet = "harness.sheet.agent-tui"
  static let agentTuiState = "harness.sheet.agent-tui.state"
  static let agentTuiCommandRoutingState = "harness.sheet.agent-tui.command-routing"
  static let agentTuiCreateTab = "harness.sheet.agent-tui.tab.create"
  static let agentTuiCreateModePicker = "harness.sheet.agent-tui.create-mode"
  static let agentTuiRuntimePicker = "harness.sheet.agent-tui.runtime"
  static let agentTuiNameField = "harness.sheet.agent-tui.name"
  static let agentTuiPromptField = "harness.sheet.agent-tui.prompt"
  static let agentTuiLaunchPane = "harness.sheet.agent-tui.launch-pane"
  static let agentTuiSessionPane = "harness.sheet.agent-tui.session-pane"
  static let agentTuiViewport = "harness.sheet.agent-tui.viewport"
  static let agentTuiControls = "harness.sheet.agent-tui.controls"
  static let agentTuiInputField = "harness.sheet.agent-tui.input"
  static let agentTuiInputModePicker = "harness.sheet.agent-tui.input-mode"
  static let agentTuiSubmitWithEnterToggle = "harness.sheet.agent-tui.submit-with-enter"
  static let agentTuiRefreshButton = "harness.sheet.agent-tui.refresh"
  static let agentTuiStartButton = "harness.sheet.agent-tui.start"
  static let agentTuiSendButton = "harness.sheet.agent-tui.send"
  static let agentTuiResizeButton = "harness.sheet.agent-tui.resize"
  static let agentTuiStopButton = "harness.sheet.agent-tui.stop"
  static let agentTuiRevealTranscriptButton = "harness.sheet.agent-tui.transcript"
  static let agentTuiRecoveryBanner = "harness.sheet.agent-tui.recovery-banner"
  static let agentTuiEnableBridgeButton = "harness.sheet.agent-tui.enable-bridge"
  static let agentTuiCopyCommandButton = "harness.sheet.agent-tui.copy-command"
  static let agentTuiBackToCreateButton = "harness.sheet.agent-tui.back-to-create"
  static let agentTuiWrapToggle = "harness.sheet.agent-tui.wrap-toggle"
  static let agentTuiNavigateBackButton = "harness.sheet.agent-tui.navigate-back"
  static let agentTuiNavigateForwardButton = "harness.sheet.agent-tui.navigate-forward"
  static let agentTuiPersonaPicker = "harness.window.agents.persona"
  static func agentTuiPersonaCard(_ identifier: String) -> String {
    "harness.window.agents.persona.\(identifier)"
  }
  static let agentsModelPicker = "harness.window.agents.model"
  static let agentsCustomModelField = "harness.window.agents.model.custom"
  static let agentsEffortPicker = "harness.window.agents.effort"
  static let agentsCodexModelPicker = "harness.window.agents.codex.model"
  static let agentsCodexCustomModelField = "harness.window.agents.codex.model.custom"
  static let agentsCodexEffortPicker = "harness.window.agents.codex.effort"
  static let agentsCodexPromptField = "harness.window.agents.codex.prompt"
  static let agentsCodexContextField = "harness.window.agents.codex.context"
  static let agentsCodexModePicker = "harness.window.agents.codex.mode"
  static let agentsCodexSubmitButton = "harness.window.agents.codex.submit"
  static let agentsCodexSteerButton = "harness.window.agents.codex.steer"
  static let agentsCodexInterruptButton = "harness.window.agents.codex.interrupt"
  static let agentsCodexFinalMessage = "harness.window.agents.codex.final"
  static let agentsCodexLatestSummary = "harness.window.agents.codex.latest"
  static let agentsCodexErrorMessage = "harness.window.agents.codex.error"
  static let agentsCodexRecoveryBanner = "harness.window.agents.codex.recovery-banner"
  static let agentsCodexEnableBridgeButton = "harness.window.agents.codex.enable-bridge"
  static let agentsCodexCopyCommandButton = "harness.window.agents.codex.copy-command"

  static func sessionEmptyState(_ section: String) -> String {
    "harness.session.empty-state.\(slug(section))"
  }

  static func preferencesSectionButton(_ key: String) -> String {
    "harness.preferences.section.\(key)"
  }

  static func sessionTimelinePaginationPageButton(_ pageNumber: Int) -> String {
    "harness.session.timeline.pagination.page.\(pageNumber)"
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

  static func sidebarSortSegment(_ order: String) -> String {
    "harness.sidebar.sort.\(slug(order))"
  }

  static func sidebarFocusChip(_ filter: String) -> String {
    "harness.sidebar.focus-chip.\(slug(filter))"
  }

  static let leaderAgentTuiMarker = "harness.session.agent.leader-claude.tui-marker"
  static let workerAgentTuiMarker = "harness.session.agent.worker-codex.tui-marker"

  static func sessionAgentTuiMarker(_ agentID: String) -> String {
    "harness.session.agent.\(slug(agentID)).tui-marker"
  }

  static func sessionAgentTaskDropFeedback(_ agentID: String) -> String {
    "harness.session.agent.\(slug(agentID)).task-drop-feedback"
  }

  static func sessionRow(_ sessionID: String) -> String {
    "harness.sidebar.session.\(slug(sessionID))"
  }

  static func agentTuiTab(_ tuiID: String) -> String {
    "harness.sheet.agent-tui.tab.\(slug(tuiID))"
  }

  static func segmentedOption(_ controlID: String, option: String) -> String {
    "\(controlID).option.\(slug(option))"
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
