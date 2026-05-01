extension HarnessMonitorUITestAccessibility {
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
  static let agentsDecisionDesk = "harness.window.agents.decisions"
  static let agentsDecisionFiltersMenu = "harness.window.agents.decisions.filters"
  static let agentsDecisionFilterState = "harness.window.agents.decisions.filter-state"
  static let agentTuiPersonaPicker = "harness.window.agents.persona"
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
  static let toolCallTimeline = "harness.window.agents.tool-call-timeline"
  static let agentsCodexSteerButton = "harness.window.agents.codex.steer"
  static let agentsCodexInterruptButton = "harness.window.agents.codex.interrupt"
  static let agentsCodexFinalMessage = "harness.window.agents.codex.final"
  static let agentsCodexLatestSummary = "harness.window.agents.codex.latest"
  static let agentsCodexErrorMessage = "harness.window.agents.codex.error"
  static let agentsCodexRecoveryBanner = "harness.window.agents.codex.recovery-banner"
  static let agentsCodexEnableBridgeButton = "harness.window.agents.codex.enable-bridge"
  static let agentsCodexCopyCommandButton = "harness.window.agents.codex.copy-command"
  static let agentsTaskCard = "harness.agents.task.card"
  static let agentsTaskNoteField = "harness.agents.task.note-field"
  static let agentsTaskNoteAddButton = "harness.agents.task.note-add"
  static let agentsTaskNotesUnavailable = "harness.agents.task.notes-unavailable"
  static let signalDetailSheet = "harness.signal.detail.sheet"
  static let signalDetailCard = "harness.signal.detail.card"
  static let signalDetailDismissButton = "harness.signal.detail.dismiss"

  static func agentTuiPersonaCard(_ identifier: String) -> String {
    "harness.window.agents.persona.\(identifier)"
  }

  static func agentCapabilityRow(_ identifier: String) -> String {
    "harness.window.agents.capability.\(slug(identifier))"
  }

  static func agentCapabilityInstallButton(_ identifier: String) -> String {
    "harness.window.agents.capability.\(slug(identifier)).install"
  }

  static func agentCapabilityProbe(_ identifier: String) -> String {
    "harness.window.agents.capability.\(slug(identifier)).probe"
  }

  static func agentCapabilityTransportButton(_ identifier: String, transportID: String) -> String {
    "harness.window.agents.capability.\(slug(identifier)).transport.\(slug(transportID))"
  }

  static func codexApprovalButton(_ approvalID: String, decision: String) -> String {
    "harness.window.agents.codex.approval.\(slug(approvalID)).\(slug(decision))"
  }

  static func agentsTaskTab(_ taskID: String) -> String {
    "harness.agents.task.tab.\(slug(taskID))"
  }

  static func agentsTaskSelection(_ taskID: String) -> String {
    "harness.agents.task.selection.\(slug(taskID))"
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
    "harness.agents.detail.awaiting-decision.\(slug(agentID))"
  }

  static func agentDetailOpenDecisionsButton(_ agentID: String) -> String {
    "harness.agents.detail.awaiting-decision.open.\(slug(agentID))"
  }

  static func agentRuntimeStrip(_ agentID: String) -> String {
    "harness.agents.detail.runtime.strip.\(slug(agentID))"
  }

  static func agentRuntimeWatchdog(_ agentID: String) -> String {
    "harness.agents.detail.runtime.watchdog.\(slug(agentID))"
  }

  static func agentRuntimePendingPermissions(_ agentID: String) -> String {
    "harness.agents.detail.runtime.pending-permissions.\(slug(agentID))"
  }

  static func agentRuntimeDeadline(_ agentID: String) -> String {
    "harness.agents.detail.runtime.deadline.\(slug(agentID))"
  }

  static func agentRuntimeDisclosure(_ agentID: String) -> String {
    "harness.agents.detail.runtime.disclosure.\(slug(agentID))"
  }

  static func agentRuntimeDisclosureContent(_ agentID: String) -> String {
    "harness.agents.detail.runtime.disclosure-content.\(slug(agentID))"
  }

  static func agentTuiKeyButton(_ key: String) -> String {
    "harness.sheet.agent-tui.key.\(slug(key))"
  }

  static func segmentedOption(_ controlID: String, option: String) -> String {
    "\(controlID).option.\(slug(option))"
  }
}
