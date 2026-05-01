extension HarnessMonitorUITestAccessibility {
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
  static let agentTuiKeyQueueHint = "harness.sheet.agent-tui.key-queue"
  static let agentTuiSubmitWithEnterToggle = "harness.sheet.agent-tui.submit-with-enter"
  static let agentTuiRefreshButton = "harness.sheet.agent-tui.refresh"
  static let agentTuiStartButton = "harness.sheet.agent-tui.start"
  static let agentTuiSendButton = "harness.sheet.agent-tui.send"
  static let agentTuiResizeButton = "harness.sheet.agent-tui.resize"
  static let agentTuiStopButton = "harness.sheet.agent-tui.stop"
  static let agentTuiRevealTranscriptButton = "harness.sheet.agent-tui.transcript"
  static let agentTuiRecoveryBanner = "harness.sheet.agent-tui.recovery-banner"
  static let agentTuiSessionActionBanner = "harness.sheet.agent-tui.session-action-banner"
  static let agentTuiEnableBridgeButton = "harness.sheet.agent-tui.enable-bridge"
  static let agentTuiNewSessionButton = "harness.sheet.agent-tui.new-session"
  static let agentTuiCopyCommandButton = "harness.sheet.agent-tui.copy-command"
  static let agentTuiBackToCreateButton = "harness.sheet.agent-tui.back-to-create"
  static let agentTuiWrapToggle = "harness.sheet.agent-tui.wrap-toggle"
  static let agentTuiNavigateBackButton = "harness.sheet.agent-tui.navigate-back"
  static let agentTuiNavigateForwardButton = "harness.sheet.agent-tui.navigate-forward"
  static let decisionsSidebarSearchScopeMenu = "harness.decisions.sidebar.search.scope"
  static let decisionsSidebarFilterToggle = "harness.decisions.sidebar.filter.toggle"
  static let workspaceDecisionDesk = "harness.window.workspace.decisions"
  static let workspaceDecisionFiltersMenu = "harness.window.workspace.decisions.filters"
  static let workspaceDecisionClearFiltersButton =
    "harness.window.workspace.decisions.clear-filters"
  static let workspaceDecisionFilterState = "harness.window.workspace.decisions.filter-state"
  static let workspacePersonaPicker = "harness.window.workspace.persona"
  static let workspaceModelPicker = "harness.window.workspace.model"
  static let workspaceCustomModelField = "harness.window.workspace.model.custom"
  static let workspaceEffortPicker = "harness.window.workspace.effort"
  static let workspaceCodexModelPicker = "harness.window.workspace.codex.model"
  static let workspaceCodexCustomModelField = "harness.window.workspace.codex.model.custom"
  static let workspaceCodexEffortPicker = "harness.window.workspace.codex.effort"
  static let workspaceCodexPromptField = "harness.window.workspace.codex.prompt"
  static let workspaceCodexContextField = "harness.window.workspace.codex.context"
  static let workspaceCodexModePicker = "harness.window.workspace.codex.mode"
  static let workspaceCodexSubmitButton = "harness.window.workspace.codex.submit"
  static let workspaceToolCallTimeline = "harness.window.workspace.tool-call-timeline"
  static let workspaceCodexSteerButton = "harness.window.workspace.codex.steer"
  static let workspaceCodexInterruptButton = "harness.window.workspace.codex.interrupt"
  static let workspaceCodexFinalMessage = "harness.window.workspace.codex.final"
  static let workspaceCodexLatestSummary = "harness.window.workspace.codex.latest"
  static let workspaceCodexErrorMessage = "harness.window.workspace.codex.error"
  static let workspaceCodexRecoveryBanner = "harness.window.workspace.codex.recovery-banner"
  static let workspaceCodexEnableBridgeButton = "harness.window.workspace.codex.enable-bridge"
  static let workspaceCodexCopyCommandButton = "harness.window.workspace.codex.copy-command"
  static let workspaceTaskCard = "harness.workspace.task.card"
  static let workspaceTaskNoteField = "harness.workspace.task.note-field"
  static let workspaceTaskNoteAddButton = "harness.workspace.task.note-add"
  static let workspaceTaskNotesUnavailable = "harness.workspace.task.notes-unavailable"
  static let signalDetailSheet = "harness.signal.detail.sheet"
  static let signalDetailCard = "harness.signal.detail.card"
  static let signalDetailDismissButton = "harness.signal.detail.dismiss"

  static func workspacePersonaCard(_ identifier: String) -> String {
    "harness.window.workspace.persona.\(identifier)"
  }

  static func agentCapabilityRow(_ identifier: String) -> String {
    "harness.window.workspace.capability.\(slug(identifier))"
  }

  static func agentCapabilityInstallButton(_ identifier: String) -> String {
    "harness.window.workspace.capability.\(slug(identifier)).install"
  }

  static func agentCapabilityProbe(_ identifier: String) -> String {
    "harness.window.workspace.capability.\(slug(identifier)).probe"
  }

  static func agentCapabilityTransportButton(_ identifier: String, transportID: String) -> String {
    "harness.window.workspace.capability.\(slug(identifier)).transport.\(slug(transportID))"
  }

  static func codexApprovalButton(_ approvalID: String, decision: String) -> String {
    "harness.window.workspace.codex.approval.\(slug(approvalID)).\(slug(decision))"
  }

  static func workspaceTaskTab(_ taskID: String) -> String {
    "harness.workspace.task.tab.\(slug(taskID))"
  }

  static func workspaceTaskSelection(_ taskID: String) -> String {
    "harness.workspace.task.selection.\(slug(taskID))"
  }

  static func agentTuiTab(_ tuiID: String) -> String {
    "harness.sheet.agent-tui.tab.\(slug(tuiID))"
  }

  static func agentTuiExternalTab(_ agentID: String) -> String {
    "harness.sheet.agent-tui.external-tab.\(slug(agentID))"
  }

  static func agentPendingDecisionBadge(_ agentID: String) -> String {
    "harness.sheet.agent-tui.pending-decision-badge.\(slug(agentID))"
  }

  static func agentDetailAwaitingDecisionStrip(_ agentID: String) -> String {
    "harness.workspace.detail.awaiting-decision.\(slug(agentID))"
  }

  static func agentDetailOpenDecisionsButton(_ agentID: String) -> String {
    "harness.workspace.detail.awaiting-decision.open.\(slug(agentID))"
  }

  static func agentRuntimeStrip(_ agentID: String) -> String {
    "harness.workspace.detail.runtime.strip.\(slug(agentID))"
  }

  static func agentRuntimeWatchdog(_ agentID: String) -> String {
    "harness.workspace.detail.runtime.watchdog.\(slug(agentID))"
  }

  static func agentRuntimePendingPermissions(_ agentID: String) -> String {
    "harness.workspace.detail.runtime.pending-permissions.\(slug(agentID))"
  }

  static func agentRuntimeDeadline(_ agentID: String) -> String {
    "harness.workspace.detail.runtime.deadline.\(slug(agentID))"
  }

  static func agentRuntimeDisclosure(_ agentID: String) -> String {
    "harness.workspace.detail.runtime.disclosure.\(slug(agentID))"
  }

  static func agentRuntimeDisclosureContent(_ agentID: String) -> String {
    "harness.workspace.detail.runtime.disclosure-content.\(slug(agentID))"
  }

  static func agentTuiKeyButton(_ key: String) -> String {
    "harness.sheet.agent-tui.key.\(slug(key))"
  }

  static func segmentedOption(_ controlID: String, option: String) -> String {
    "\(controlID).option.\(slug(option))"
  }
}
