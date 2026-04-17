import SwiftUI

public enum HarnessMonitorAccessibility {
  public static let appChromeRoot = "harness.app.chrome"
  public static let appChromeState = "harness.app.chrome.state"
  public static let auditBuildState = "harness.audit.build.state"
  public static let auditBuildBadge = "harness.audit.build.badge"
  public static let perfScenarioState = "harness.perf.scenario.state"
  public static let toolbarChromeState = "harness.toolbar.chrome.state"
  public static let toolbarBaselineDivider = "harness.toolbar.baseline-divider"
  public static let persistenceBanner = "harness.persistence.banner"
  public static let persistedDataBanner = "harness.persisted-data.banner"
  public static let persistedDataBannerFrame = "\(persistedDataBanner).frame"
  public static let sessionStatusCorner = "harness.session-status.corner"
  public static let sessionStatusCornerFrame = "\(sessionStatusCorner).frame"
  public static let sidebarRoot = "harness.sidebar.root"
  public static let sidebarShellFrame = "harness.sidebar.shell.frame"
  public static let sidebarEmptyState = "harness.sidebar.empty-state"
  public static let sidebarEmptyStateFrame = "\(sidebarEmptyState).frame"
  public static let sidebarSessionList = "harness.sidebar.session-list"
  public static let sidebarSessionListContent = "harness.sidebar.session-list.content"
  public static let sidebarSessionListState = "harness.sidebar.session-list.state"
  public static let sidebarFiltersCard = "harness.sidebar.filters"
  public static let sidebarFiltersCardFrame = "\(sidebarFiltersCard).frame"
  public static let sidebarFilterMenu = "harness.toolbar.sidebar-filters"
  public static let sidebarFilterState = "harness.sidebar.filter.state"
  public static let sidebarFiltersToggle = sidebarFilterMenu
  public static let sidebarSearchField = "harness.sidebar.search"
  public static let sidebarClearFiltersButton = "harness.sidebar.filters.clear"
  public static let sidebarClearSearchHistoryButton = "harness.sidebar.search.clear-history"
  public static let sessionFilterGroup = "harness.sidebar.filter-group"
  public static let sidebarSortPicker = "harness.sidebar.picker.sort"
  public static let sidebarFocusPicker = "harness.sidebar.picker.focus"
  public static let sidebarFooter = "harness.sidebar.footer"
  public static let sidebarFooterState = "harness.sidebar.footer.state"
  public static let sidebarFooterMetricsFrame = "harness.sidebar.footer.metrics.frame"

  public static func sidebarFilterChip(_ filter: String) -> String {
    "harness.sidebar.filter-chip.\(slug(filter))"
  }

  public static func sidebarFocusChip(_ filter: String) -> String {
    "harness.sidebar.focus-chip.\(slug(filter))"
  }

  public static func sidebarSortSegment(_ order: String) -> String {
    "harness.sidebar.sort.\(slug(order))"
  }

  public static let sessionsBoardRoot = "harness.board.root"
  public static let recentSessionsCard = "harness.board.recent-sessions-card"
  public static let contentRoot = "harness.content.root"
  public static let inspectorRoot = "harness.inspector.root"
  public static let inspectorEmptyState = "harness.inspector.empty-state"
  public static let inspectorLoadingState = "harness.inspector.loading-state"
  public static let sessionInspectorCard = "harness.inspector.session-card"
  public static let taskInspectorCard = "harness.inspector.task-card"
  public static let taskNoteField = "harness.inspector.task-note-field"
  public static let taskNoteAddButton = "harness.inspector.task-note-add"
  public static let taskNotesUnavailable = "harness.inspector.task-notes-unavailable"
  public static let agentInspectorCard = "harness.inspector.agent-card"
  public static let signalInspectorCard = "harness.inspector.signal-card"
  public static let observerInspectorCard = "harness.inspector.observer-card"
  public static let actionActorPicker = "harness.inspector.action-actor"
  public static let signalCommandField = "harness.inspector.signal-command"
  public static let signalMessageField = "harness.inspector.signal-message"
  public static let createTaskTitleField = "harness.inspector.create-task.title"
  public static let createTaskButton = "harness.inspector.create-task"
  public static let assignTaskButton = "harness.inspector.assign-task"
  public static let updateTaskQueuePolicyButton = "harness.inspector.update-task-queue-policy"
  public static let updateTaskStatusButton = "harness.inspector.update-task-status"
  public static let checkpointTaskButton = "harness.inspector.checkpoint-task"
  public static let changeRoleButton = "harness.inspector.change-role"
  public static let removeAgentButton = "harness.inspector.remove-agent"
  public static let signalSendButton = "harness.inspector.signal-send"
  public static let leaderTransferSection = "harness.inspector.leader-transfer"
  public static let leaderTransferPicker = "harness.inspector.leader-transfer-picker"
  public static let preferencesRoot = "harness.preferences.root"
  public static let preferencesState = "harness.preferences.state"
  public static let preferencesPanel = "harness.preferences.panel"
  public static let preferencesToolbarSeparatorSuppressed =
    "harness.preferences.toolbar.separator-suppressed"
  public static let preferencesSidebar = "harness.preferences.sidebar"
  public static let preferencesBackButton = "harness.preferences.nav.back"
  public static let preferencesForwardButton = "harness.preferences.nav.forward"
  public static let preferencesTitle = "harness.preferences.title"
  public static let preferencesThemeModePicker = "harness.preferences.theme-mode"
  public static let preferencesBackdropModePicker = "harness.preferences.backdrop-mode"
  public static let preferencesBackgroundCollectionPicker = "harness.preferences.background-collection"
  public static let preferencesBackgroundGallery = "harness.preferences.background-gallery"
  public static let preferencesBackgroundRecentsSection = "harness.preferences.background.recents-section"
  public static let preferencesBackgroundRecentState = "harness.preferences.background.recents-state"
  public static let preferencesTextSizePicker = "harness.preferences.text-size"
  public static let preferencesTimeZoneModePicker = "harness.preferences.time-zone-mode"
  public static let preferencesCustomTimeZonePicker = "harness.preferences.custom-time-zone"
  public static let preferencesVoiceSection = "harness.preferences.voice"
  public static let preferencesVoiceLocaleField = "harness.preferences.voice.locale-field"
  public static let preferencesVoiceLocalePicker = "harness.preferences.voice.locale-picker"
  public static let preferencesVoiceLocalDaemonToggle = "harness.preferences.voice.local-daemon"
  public static let preferencesVoiceAgentBridgeToggle = "harness.preferences.voice.agent-bridge"
  public static let preferencesVoiceRemoteProcessorToggle =
    "harness.preferences.voice.remote-processor"
  public static let preferencesVoiceRemoteProcessorURLField =
    "harness.preferences.voice.remote-processor-url"
  public static let preferencesVoiceInsertionModePicker = "harness.preferences.voice.insertion-mode"
  public static let preferencesVoiceAudioChunksToggle = "harness.preferences.voice.audio-chunks"
  public static let preferencesVoicePendingAudioField =
    "harness.preferences.voice.pending-audio-limit"
  public static let preferencesVoicePendingTranscriptField =
    "harness.preferences.voice.pending-transcript-limit"
  public static let preferencesVoiceStatus = "harness.preferences.voice.status"
  public static let preferencesNotificationsStatus = "harness.preferences.notifications.status"
  public static let preferencesNotificationsPresetPicker = "harness.preferences.notifications.preset"
  public static let preferencesNotificationsCategoryPicker = "harness.preferences.notifications.category"
  public static let preferencesNotificationsSoundPicker = "harness.preferences.notifications.sound"
  public static let preferencesNotificationsAttachmentPicker =
    "harness.preferences.notifications.attachment"
  public static let preferencesNotificationsTriggerPicker = "harness.preferences.notifications.trigger"
  public static let preferencesNotificationsSendButton = "harness.preferences.notifications.send"
  public static let navigateBackButton = "harness.toolbar.navigate-back"
  public static let navigateForwardButton = "harness.toolbar.navigate-forward"
  public static let toolbarCenterpiece = "harness.toolbar.centerpiece"
  public static let toolbarCenterpieceFrame = "harness.toolbar.centerpiece.frame"
  public static let toolbarCenterpieceMode = "harness.toolbar.centerpiece.mode"
  public static let toolbarStatusTicker = "harness.toolbar.status-ticker"
  public static let toolbarStatusTickerFrame = "harness.toolbar.status-ticker.frame"
  public static let toolbarStatusTickerContentFrame = "harness.toolbar.status-ticker.content.frame"
  public static let refreshButton = "harness.toolbar.refresh"
  public static let daemonPreferencesButton = "harness.toolbar.preferences"
  public static let inspectorToggleButton = "harness.toolbar.inspector-toggle"
  public static let sleepPreventionButton = "harness.toolbar.sleep-prevention"
  public static let sessionHeaderCard = "harness.session.header"
  public static let sessionHeaderCardFrame = "\(sessionHeaderCard).frame"
  public static let observeSessionButton = "harness.session.action.observe"
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
  public static let sessionTimelinePagination = "harness.session.timeline.pagination"
  public static let sessionTimelinePageSizePicker = "harness.session.timeline.pagination.page-size"
  public static let sessionTimelinePaginationPrevious = "harness.session.timeline.pagination.previous"
  public static let sessionTimelinePaginationNext = "harness.session.timeline.pagination.next"
  public static let sessionTimelinePaginationStatus = "harness.session.timeline.pagination.status"
  public static let connectionCard = "harness.preferences.connection-card"
  public static let cornerOverlay = "harness.corner-overlay"
  public static let agentTuiButton = "harness.session.agent-tui"
  public static let agentTuiSheet = "harness.sheet.agent-tui"
  public static let agentTuiState = "harness.sheet.agent-tui.state"
  public static let agentTuiCommandRoutingState = "harness.sheet.agent-tui.command-routing"
  public static let agentTuiCreateTab = "harness.sheet.agent-tui.tab.create"
  public static let agentTuiRuntimePicker = "harness.sheet.agent-tui.runtime"
  public static let agentTuiNameField = "harness.sheet.agent-tui.name"
  public static let agentTuiPromptField = "harness.sheet.agent-tui.prompt"
  public static let agentTuiProjectDirField = "harness.sheet.agent-tui.project-dir"
  public static let agentTuiArgvField = "harness.sheet.agent-tui.argv"
  public static let agentTuiLaunchPane = "harness.sheet.agent-tui.launch-pane"
  public static let agentTuiSessionPane = "harness.sheet.agent-tui.session-pane"
  public static let agentTuiViewport = "harness.sheet.agent-tui.viewport"
  public static let agentTuiInputField = "harness.sheet.agent-tui.input"
  public static let agentTuiInputModePicker = "harness.sheet.agent-tui.input-mode"
  public static let agentTuiRefreshButton = "harness.sheet.agent-tui.refresh"
  public static let agentTuiStartButton = "harness.sheet.agent-tui.start"
  public static let agentTuiSendButton = "harness.sheet.agent-tui.send"
  public static let agentTuiResizeButton = "harness.sheet.agent-tui.resize"
  public static let agentTuiStopButton = "harness.sheet.agent-tui.stop"
  public static let agentTuiRevealTranscriptButton = "harness.sheet.agent-tui.transcript"
  public static let agentTuiRecoveryBanner = "harness.sheet.agent-tui.recovery-banner"
  public static let agentTuiEnableBridgeButton = "harness.sheet.agent-tui.enable-bridge"
  public static let agentTuiCopyCommandButton = "harness.sheet.agent-tui.copy-command"
  public static let agentTuiBackToCreateButton = "harness.sheet.agent-tui.back-to-create"
  public static let agentTuiWrapToggle = "harness.sheet.agent-tui.wrap-toggle"
  public static let agentTuiNavigateBackButton = "harness.sheet.agent-tui.navigate-back"
  public static let agentTuiNavigateForwardButton = "harness.sheet.agent-tui.navigate-forward"
  public static let agentTuiPersonaPicker = "harness.sheet.agent-tui.persona-picker"
  public static func agentTuiPersonaCard(_ identifier: String) -> String {
    "harness.sheet.agent-tui.persona.\(identifier)"
  }
  public static let codexFlowButton = "harness.session.codex-flow"
  public static let codexFlowPlaceholderIcon = "harness.session.codex-flow.placeholder-icon"
  public static let codexFlowSheet = "harness.sheet.codex-flow"
  public static let codexFlowPromptField = "harness.sheet.codex-flow.prompt"
  public static let codexFlowPromptVoiceButton = "harness.sheet.codex-flow.prompt.voice"
  public static let codexFlowContextField = "harness.sheet.codex-flow.context"
  public static let codexFlowContextVoiceButton = "harness.sheet.codex-flow.context.voice"
  public static let codexFlowModePicker = "harness.sheet.codex-flow.mode"
  public static let codexFlowCancelButton = "harness.sheet.codex-flow.cancel"
  public static let codexFlowSubmitButton = "harness.sheet.codex-flow.submit"
  public static let codexFlowSteerButton = "harness.sheet.codex-flow.steer"
  public static let codexFlowInterruptButton = "harness.sheet.codex-flow.interrupt"
  public static let sendSignalSheet = "harness.sheet.send-signal"
  public static let sendSignalSheetCommandField = "harness.sheet.send-signal.command"
  public static let sendSignalSheetMessageField = "harness.sheet.send-signal.message"
  public static let sendSignalSheetMessageVoiceButton = "harness.sheet.send-signal.message.voice"
  public static let sendSignalSheetActionHintField = "harness.sheet.send-signal.action-hint"
  public static let sendSignalSheetCancelButton = "harness.sheet.send-signal.cancel"
  public static let sendSignalSheetSubmitButton = "harness.sheet.send-signal.submit"
  public static let preferencesCodexSection = "harness.preferences.codex"
  public static let preferencesCodexCopyStartButton = "harness.preferences.codex.copy-start"
  public static let preferencesCodexCopyInstallButton = "harness.preferences.codex.copy-install"
  public static let codexFlowRecoveryBanner = "harness.sheet.codex-flow.recovery-banner"
  public static let codexFlowEnableBridgeButton = "harness.sheet.codex-flow.enable-bridge"
  public static let codexFlowCopyCommandButton = "harness.sheet.codex-flow.copy-command"
  public static let preferencesDatabaseStatistics = "harness.preferences.database.statistics"
  public static let preferencesDatabaseStatisticsPicker =
    "harness.preferences.database.statistics-picker"
  public static let preferencesDatabaseOperations = "harness.preferences.database.operations"
  public static let preferencesDatabaseHealth = "harness.preferences.database.health"
  public static let voiceInputPopover = "harness.voice-input.popover"
  public static let voiceInputTranscript = "harness.voice-input.transcript"
  public static let voiceInputInsertButton = "harness.voice-input.insert"
  public static let voiceInputStopButton = "harness.voice-input.stop"
  public static let voiceInputRemoteURLField = "harness.voice-input.remote-url"
  public static let voiceInputFailureOverlay = "harness.voice-input.failure"
  public static let voiceInputFailureMessage = "harness.voice-input.failure.message"
  public static let voiceInputFailureInstructions = "harness.voice-input.failure.instructions"
  public static let voiceInputFailureRetryButton = "harness.voice-input.failure.retry"
  public static let voiceInputFailureCloseButton = "harness.voice-input.failure.close"

  public static func sessionRow(_ sessionID: String) -> String {
    "harness.sidebar.session.\(sessionID)"
  }

  public static func sessionRowFrame(_ sessionID: String) -> String {
    "\(sessionRow(sessionID)).frame"
  }

  public static func sessionRowSelectionFrame(_ sessionID: String) -> String {
    "\(sessionRow(sessionID)).selection.frame"
  }

  public static func sessionRowAgentStat(_ sessionID: String) -> String {
    "\(sessionRow(sessionID)).stat.agent"
  }

  public static func sessionRowTaskStat(_ sessionID: String) -> String {
    "\(sessionRow(sessionID)).stat.task"
  }

  public static func sessionRowStatsFrame(_ sessionID: String) -> String {
    "\(sessionRow(sessionID)).stats.frame"
  }

  public static func sessionRowLastActivityFrame(_ sessionID: String) -> String {
    "\(sessionRow(sessionID)).last-activity.frame"
  }

  public static func projectHeader(_ projectID: String) -> String {
    "harness.sidebar.project-header.\(slug(projectID))"
  }

  public static func projectHeaderFrame(_ projectID: String) -> String {
    "\(projectHeader(projectID)).frame"
  }

  public static func worktreeHeader(_ checkoutID: String) -> String {
    "harness.sidebar.worktree-header.\(slug(checkoutID))"
  }

  public static func worktreeHeaderFrame(_ checkoutID: String) -> String {
    "\(worktreeHeader(checkoutID)).frame"
  }

  public static func worktreeHeaderGlyph(_ checkoutID: String) -> String {
    "\(worktreeHeader(checkoutID)).glyph"
  }

  public static func sessionFilterButton(_ filter: String) -> String {
    "harness.sidebar.filter.\(filter)"
  }

  public static func sessionTaskCard(_ taskID: String) -> String {
    "harness.session.task.\(slug(taskID))"
  }

  public static func sessionAgentCard(_ agentID: String) -> String {
    "harness.session.agent.\(slug(agentID))"
  }

  public static func sessionAgentTaskDropFeedback(_ agentID: String) -> String {
    "\(sessionAgentCard(agentID)).task-drop-feedback"
  }

  public static func sessionAgentTuiMarker(_ agentID: String) -> String {
    "harness.session.agent.\(slug(agentID)).tui-marker"
  }

  public static func sessionAgentSignalTrigger(_ agentID: String) -> String {
    "harness.session.agent.\(slug(agentID)).signal-trigger"
  }

  public static func sessionSignalCard(_ signalID: String) -> String {
    "harness.session.signal.\(slug(signalID))"
  }

  public static func codexApprovalButton(_ approvalID: String, decision: String) -> String {
    "harness.sheet.codex-flow.approval.\(slug(approvalID)).\(slug(decision))"
  }

  public static func agentTuiTab(_ tuiID: String) -> String {
    "harness.sheet.agent-tui.tab.\(slug(tuiID))"
  }

  public static func agentTuiKeyButton(_ key: String) -> String {
    "harness.sheet.agent-tui.key.\(slug(key))"
  }

  public static func sessionTimelinePaginationPageButton(_ pageNumber: Int) -> String {
    "harness.session.timeline.pagination.page.\(pageNumber)"
  }

  public static func preferencesMetricCard(_ key: String) -> String {
    "harness.preferences.metric.\(slug(key))"
  }

  public static func preferencesSectionButton(_ key: String) -> String {
    "harness.preferences.section.\(slug(key))"
  }

  public static func preferencesActionButton(_ key: String) -> String {
    "harness.preferences.action.\(slug(key))"
  }

  public static func preferencesBackgroundTile(_ key: String) -> String {
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
