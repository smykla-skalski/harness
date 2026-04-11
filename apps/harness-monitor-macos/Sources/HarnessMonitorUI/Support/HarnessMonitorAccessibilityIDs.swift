import SwiftUI

public enum HarnessMonitorAccessibility {
  static let appChromeRoot = "harness.app.chrome"
  static let appChromeState = "harness.app.chrome.state"
  static let auditBuildState = "harness.audit.build.state"
  static let auditBuildBadge = "harness.audit.build.badge"
  public static let perfScenarioState = "harness.perf.scenario.state"
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
  static let preferencesVoiceSection = "harness.preferences.voice"
  static let preferencesVoiceLocaleField = "harness.preferences.voice.locale-field"
  static let preferencesVoiceLocalePicker = "harness.preferences.voice.locale-picker"
  static let preferencesVoiceLocalDaemonToggle = "harness.preferences.voice.local-daemon"
  static let preferencesVoiceAgentBridgeToggle = "harness.preferences.voice.agent-bridge"
  static let preferencesVoiceRemoteProcessorToggle =
    "harness.preferences.voice.remote-processor"
  static let preferencesVoiceRemoteProcessorURLField =
    "harness.preferences.voice.remote-processor-url"
  static let preferencesVoiceInsertionModePicker = "harness.preferences.voice.insertion-mode"
  static let preferencesVoiceAudioChunksToggle = "harness.preferences.voice.audio-chunks"
  static let preferencesVoicePendingAudioChunkLimitField =
    "harness.preferences.voice.pending-audio-limit"
  static let preferencesVoicePendingTranscriptLimitField =
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
  static let refreshButton = "harness.toolbar.refresh"
  static let daemonPreferencesButton = "harness.toolbar.preferences"
  static let inspectorToggleButton = "harness.toolbar.inspector-toggle"
  static let sleepPreventionButton = "harness.toolbar.sleep-prevention"
  static let observeSessionButton = "harness.session.action.observe"
  static let endSessionButton = "harness.session.action.end"
  static let pendingLeaderTransferCard = "harness.session.pending-transfer"
  static let connectionBadge = "harness.toolbar.connection-badge"
  static let transportBadge = "harness.sidebar.transport-badge"
  static let latencyBadge = "harness.sidebar.latency-badge"
  static let activityPulse = "harness.sidebar.activity-pulse"
  static let reconnectionProgress = "harness.sidebar.reconnection-progress"
  static let actionToast = "harness.action-toast"
  static let actionToastCloseButton = "harness.action-toast.close"
  static let sessionTimelinePagination = "harness.session.timeline.pagination"
  static let sessionTimelinePageSizePicker = "harness.session.timeline.pagination.page-size"
  static let sessionTimelinePaginationPrevious = "harness.session.timeline.pagination.previous"
  static let sessionTimelinePaginationNext = "harness.session.timeline.pagination.next"
  static let sessionTimelinePaginationStatus = "harness.session.timeline.pagination.status"
  static let connectionCard = "harness.preferences.connection-card"
  static let cornerOverlay = "harness.corner-overlay"
  static let agentTuiButton = "harness.session.agent-tui"
  static let agentTuiSheet = "harness.sheet.agent-tui"
  static let agentTuiSelector = "harness.sheet.agent-tui.selector"
  static let agentTuiRuntimePicker = "harness.sheet.agent-tui.runtime"
  static let agentTuiNameField = "harness.sheet.agent-tui.name"
  static let agentTuiPromptField = "harness.sheet.agent-tui.prompt"
  static let agentTuiInputField = "harness.sheet.agent-tui.input"
  static let agentTuiInputModePicker = "harness.sheet.agent-tui.input-mode"
  static let agentTuiRefreshButton = "harness.sheet.agent-tui.refresh"
  static let agentTuiStartButton = "harness.sheet.agent-tui.start"
  static let agentTuiSendButton = "harness.sheet.agent-tui.send"
  static let agentTuiResizeButton = "harness.sheet.agent-tui.resize"
  static let agentTuiStopButton = "harness.sheet.agent-tui.stop"
  static let agentTuiRevealTranscriptButton = "harness.sheet.agent-tui.transcript"
  static let agentTuiRecoveryBanner = "harness.sheet.agent-tui.recovery-banner"
  static let agentTuiEnableBridgeButton = "harness.sheet.agent-tui.enable-bridge"
  static let agentTuiCopyCommandButton = "harness.sheet.agent-tui.copy-command"
  static let codexFlowButton = "harness.session.codex-flow"
  static let codexFlowSheet = "harness.sheet.codex-flow"
  static let codexFlowPromptField = "harness.sheet.codex-flow.prompt"
  static let codexFlowPromptVoiceButton = "harness.sheet.codex-flow.prompt.voice"
  static let codexFlowContextField = "harness.sheet.codex-flow.context"
  static let codexFlowContextVoiceButton = "harness.sheet.codex-flow.context.voice"
  static let codexFlowModePicker = "harness.sheet.codex-flow.mode"
  static let codexFlowCancelButton = "harness.sheet.codex-flow.cancel"
  static let codexFlowSubmitButton = "harness.sheet.codex-flow.submit"
  static let codexFlowSteerButton = "harness.sheet.codex-flow.steer"
  static let codexFlowInterruptButton = "harness.sheet.codex-flow.interrupt"
  static let sendSignalSheet = "harness.sheet.send-signal"
  static let sendSignalSheetCommandField = "harness.sheet.send-signal.command"
  static let sendSignalSheetMessageField = "harness.sheet.send-signal.message"
  static let sendSignalSheetMessageVoiceButton = "harness.sheet.send-signal.message.voice"
  static let sendSignalSheetActionHintField = "harness.sheet.send-signal.action-hint"
  static let sendSignalSheetCancelButton = "harness.sheet.send-signal.cancel"
  static let sendSignalSheetSubmitButton = "harness.sheet.send-signal.submit"
  static let preferencesCodexSection = "harness.preferences.codex"
  static let preferencesCodexCopyStartButton = "harness.preferences.codex.copy-start"
  static let preferencesCodexCopyInstallButton = "harness.preferences.codex.copy-install"
  static let codexFlowRecoveryBanner = "harness.sheet.codex-flow.recovery-banner"
  static let codexFlowEnableBridgeButton = "harness.sheet.codex-flow.enable-bridge"
  static let codexFlowCopyCommandButton = "harness.sheet.codex-flow.copy-command"
  static let preferencesDatabaseStatistics = "harness.preferences.database.statistics"
  static let preferencesDatabaseOperations = "harness.preferences.database.operations"
  static let preferencesDatabaseHealth = "harness.preferences.database.health"
  static let voiceInputPopover = "harness.voice-input.popover"
  static let voiceInputTranscript = "harness.voice-input.transcript"
  static let voiceInputInsertButton = "harness.voice-input.insert"
  static let voiceInputStopButton = "harness.voice-input.stop"
  static let voiceInputRemoteURLField = "harness.voice-input.remote-url"
  static let voiceInputFailureOverlay = "harness.voice-input.failure"
  static let voiceInputFailureMessage = "harness.voice-input.failure.message"
  static let voiceInputFailureInstructions = "harness.voice-input.failure.instructions"
  static let voiceInputFailureRetryButton = "harness.voice-input.failure.retry"
  static let voiceInputFailureCloseButton = "harness.voice-input.failure.close"

  static func sessionRow(_ sessionID: String) -> String {
    "harness.sidebar.session.\(sessionID)"
  }

  static func sessionRowFrame(_ sessionID: String) -> String {
    "\(sessionRow(sessionID)).frame"
  }

  static func sessionRowSelectionFrame(_ sessionID: String) -> String {
    "\(sessionRow(sessionID)).selection.frame"
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

  static func sessionAgentTaskDropFeedback(_ agentID: String) -> String {
    "\(sessionAgentCard(agentID)).task-drop-feedback"
  }

  static func sessionAgentSignalTrigger(_ agentID: String) -> String {
    "harness.session.agent.\(slug(agentID)).signal-trigger"
  }

  static func sessionSignalCard(_ signalID: String) -> String {
    "harness.session.signal.\(slug(signalID))"
  }

  static func codexApprovalButton(_ approvalID: String, decision: String) -> String {
    "harness.sheet.codex-flow.approval.\(slug(approvalID)).\(slug(decision))"
  }

  static func agentTuiKeyButton(_ key: String) -> String {
    "harness.sheet.agent-tui.key.\(slug(key))"
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
