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
  static let menuBarOpenSession = "harness.menu-bar.action.open-session"
  static let menuBarOpenSettings = "harness.menu-bar.action.open-settings"
  static let menuBarRefresh = "harness.menu-bar.action.refresh"
  static let menuBarSupervisorToggle = "harness.menu-bar.action.supervisor-toggle"
  static let menuBarSupervisorCheckNow = "harness.menu-bar.action.supervisor-check-now"
  static let menuBarRunWhenClosed = "harness.menu-bar.action.run-when-closed"
  static let menuBarQuit = "harness.menu-bar.action.quit"
  static let sessionAttentionToolbarButton = "harness.toolbar.session-attention"
  static let sessionAttentionToolbarButtonState = "harness.toolbar.session-attention.state"
  static let sessionAttentionToolbarForceTick = "harness.toolbar.session-attention.force-tick"
  static let decisionDeskRoot = "harness.decisions.desk"
  static let agentDetailAwaitingDecisionState =
    "harness.agent.detail.awaiting-decision.state"
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

  static func sessionWindowAgentRow(_ agentID: String) -> String {
    "harness.session.window.agents.row.\(slug(agentID))"
  }

  static func sessionWindowTaskRow(_ taskID: String) -> String {
    "harness.session.window.tasks.row.\(slug(taskID))"
  }

  static func sidebarTaskRow(_ taskID: String) -> String {
    "harness.session.window.sidebar.task.\(slug(taskID))"
  }

  static let sessionHeaderCard = "harness.session.header"
  static let sessionHeaderCardFrame = "harness.session.header.frame"
  static let sidebarRoot = "harness.sidebar.root"
  static let previewSessionID = "9f62b1d4-0c8a-4c2f-9f4f-4d6cf6a13e9b"
  static let previewProjectHeader = "harness.sidebar.project-header.project-6ccf8d0a"
  static let previewProjectHeaderFrame = "harness.sidebar.project-header.project-6ccf8d0a.frame"
  static let previewCheckoutHeader = "harness.sidebar.worktree-header.\(previewSessionID)"
  static let previewCheckoutHeaderFrame =
    "harness.sidebar.worktree-header.\(previewSessionID).frame"
  static let previewCheckoutHeaderGlyph =
    "harness.sidebar.worktree-header.\(previewSessionID).glyph"
  static let previewSessionRow = "harness.sidebar.session.\(previewSessionID)"
  static let previewSessionRowFrame = "harness.sidebar.session.\(previewSessionID).frame"
  static let previewSessionRowSelectionFrame =
    "harness.sidebar.session.\(previewSessionID).selection.frame"
  static let previewSessionRowAgentStat = "harness.sidebar.session.\(previewSessionID).stat.agent"
  static let previewSessionRowTaskStat = "harness.sidebar.session.\(previewSessionID).stat.task"
  static let previewSessionRowStatsFrame = "harness.sidebar.session.\(previewSessionID).stats.frame"
  static let previewSessionRowLastActivityFrame =
    "harness.sidebar.session.\(previewSessionID).last-activity.frame"
  static let signalRegressionSecondarySessionRow = "harness.sidebar.session.sess-harness-secondary"
  static let previewSignalCard = "harness.session.signal.sig-ui-1"
  static let signalDetailSheet = "harness.signal.detail.sheet"
  static let newCodexAgentSheet = "harness.new-codex-agent.sheet"
  static let signalDetailCard = "harness.signal.detail.card"
  static let signalDetailDismissButton = "harness.signal.detail.dismiss"
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
  static let dashboardWindowRoot = "harness.dashboard.window"
  static let dashboardSidebar = "harness.dashboard.sidebar"
  static let dashboardScrollView = "harness.dashboard.scroll"
  static let dashboardNotificationsRoot = "harness.dashboard.notifications"
  static let dashboardNotificationsScrollView = "harness.dashboard.notifications.scroll"
  static let dashboardNotificationsEmptyState = "harness.dashboard.notifications.empty-state"
  static let dashboardReviewsRoot = "harness.dashboard.reviews"
  static let dashboardReviewsList = "harness.dashboard.reviews.list"
  static let dashboardReviewsDetail = "harness.dashboard.reviews.detail"
  static let dashboardReviewsDetailDivider =
    "harness.dashboard.reviews.content-detail-divider"
  static let dashboardReviewsRefreshButton = "harness.dashboard.reviews.refresh"
  static let dashboardReviewsConfigureButton = "harness.dashboard.reviews.configure"
  static let dashboardReviewsFixCIButton = "harness.dashboard.reviews.fix-ci"
  static let dashboardReviewsSelectionStatus = "harness.dashboard.reviews.selection"
  static let dashboardReviewsFilterPicker = "harness.dashboard.reviews.filter"
  static let dashboardReviewsSortPicker = "harness.dashboard.reviews.sort"
  static let dashboardReviewsGroupPicker = "harness.dashboard.reviews.group"
  static let dashboardReviewsCategoryToggle = "harness.dashboard.reviews.category"
  static let dashboardReviewsNeedsMeToggle = "harness.dashboard.reviews.needs-me"
  static let dashboardNewSessionButton = "harness.dashboard.new-session"
  static let dashboardOpenFolderButton = "harness.dashboard.open-folder"
  static let sessionsBoardRoot = dashboardWindowRoot
  static let sessionsBoardScrollView = dashboardScrollView
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
  static let actionToast = "harness.action-toast"
  static let actionToastFrame = "harness.action-toast.frame"
  static let actionToastCloseButton = "harness.action-toast.close"
  static let acpPermissionToast = "harness.acp-permission.toast"
  static let acpPermissionToastFrame = "harness.acp-permission.toast.frame"
  static let acpPermissionToastState = "harness.acp-permission.toast.state"
  static let acpPermissionToastAccessibilityState =
    "harness.acp-permission.toast.accessibility.state"
  static let toolCallTimelineAccessibilityState =
    "harness.timeline.tool-call.accessibility.state"
  static let agentRuntimeWatchdogAccessibilityState =
    "harness.agent.detail.runtime.watchdog.accessibility.state"
  static let acpPermissionToastRouteState = "harness.acp-permission.toast.route.state"
  static let acpPermissionToastActionButton = "harness.acp-permission.toast.open-decisions"
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
  static let agentDetailScrollView = "harness.agent.detail.scroll"
  static let sessionTaskDetailScrollView = "harness.session.task.detail.scroll"
  static let sessionTimelineFilterBar = "harness.session.timeline.filters"
  static let sessionTimelineFilterState = "harness.session.timeline.filters.state"

  static func sessionAgentTuiMarker(_ agentID: String) -> String {
    "harness.session.agent.\(slug(agentID)).tui-marker"
  }

  static func sessionAgentTaskDropFeedback(_ agentID: String) -> String {
    "harness.session.agent.\(slug(agentID)).task-drop-feedback"
  }

  static func sessionAgentCard(_ agentID: String) -> String {
    "harness.session.agent.\(slug(agentID))"
  }

  static let sessionTaskCard = "harness.session.task.card"

  static func sessionTaskCard(_ taskID: String) -> String {
    "harness.session.task.\(slug(taskID))"
  }

  static let sessionAgentListHeader = "harness.session.agents.header"
  static let sessionAgentListHeaderFrame = "\(sessionAgentListHeader).frame"
  static let sessionTaskListHeader = "harness.session.tasks.header"
  static let sessionTaskListHeaderFrame = "\(sessionTaskListHeader).frame"
  static let sessionTaskListState = "harness.session.tasks.state"
  static let sessionTaskNoteField = "harness.session.task.note-field"
  static let sessionTaskNoteAddButton = "harness.session.task.note-add"
  static let sessionTaskNotesUnavailable = "harness.session.task.notes-unavailable"
  static func agentRowPersonaChip(_ agentID: String) -> String {
    "\(sessionAgentCard(agentID)).persona"
  }

  static func sessionRow(_ sessionID: String) -> String {
    "harness.sidebar.session.\(slug(sessionID))"
  }

  static func dashboardWindowRoute(_ route: String) -> String {
    "harness.dashboard.route.\(slug(route))"
  }

  static func dashboardNotificationRow(_ entryID: String) -> String {
    "harness.dashboard.notifications.row.\(slug(entryID))"
  }

  static func dashboardNotificationAction(_ entryID: String, actionID: String) -> String {
    "\(dashboardNotificationRow(entryID)).action.\(slug(actionID))"
  }

  static let policyCanvasRoot = "harness.policy-canvas.root"
  static let policyCanvasTopBar = "harness.policy-canvas.top-bar"
  static let policyCanvasViewport = "harness.policy-canvas.viewport"
  static let policyCanvasTabs = "harness.policy-canvas.tabs"
  static let policyCanvasToolRail = "harness.policy-canvas.tool-rail"
  static let policyCanvasSaveButton = "harness.policy-canvas.action.save"
  static let policyCanvasSimulateButton = "harness.policy-canvas.action.simulate"
  static let policyCanvasPromoteButton = "harness.policy-canvas.action.promote"
  static let policyCanvasZoomControls = "harness.policy-canvas.zoom"
  static let policyCanvasZoomOutButton = "harness.policy-canvas.zoom.out"
  static let policyCanvasZoomInButton = "harness.policy-canvas.zoom.in"
  static let policyCanvasZoomResetButton = "harness.policy-canvas.zoom.reset"
  static let policyCanvasZoomValue = "harness.policy-canvas.zoom.value"
  static let policyCanvasInspector = "harness.policy-canvas.inspector"

  static func policyCanvasInspectorField(_ fieldID: String) -> String {
    "harness.policy-canvas.inspector.\(slug(fieldID))"
  }

  static func policyCanvasNode(_ nodeID: String) -> String {
    "harness.policy-canvas.node.\(slug(nodeID))"
  }

  static func policyCanvasGroup(_ groupID: String) -> String {
    "harness.policy-canvas.group.\(slug(groupID))"
  }

  static func policyCanvasPort(_ nodeID: String, _ portID: String) -> String {
    "\(policyCanvasNode(nodeID)).port.\(slug(portID))"
  }

  static func policyCanvasEdge(_ edgeID: String) -> String {
    "harness.policy-canvas.edge.\(slug(edgeID))"
  }

  static func policyCanvasPaletteItem(_ kind: String) -> String {
    "harness.policy-canvas.palette.\(slug(kind))"
  }

  static func segmentedOption(_ controlID: String, option: String) -> String {
    "\(controlID).option.\(slug(option))"
  }

  static func agentCapabilityRow(_ identifier: String) -> String {
    "harness.agent.capability.\(slug(identifier))"
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
