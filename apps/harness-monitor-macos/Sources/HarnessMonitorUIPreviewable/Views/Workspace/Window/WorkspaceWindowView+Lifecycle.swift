import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
  func prepareWorkspace() async {
    workspacePreparationComplete = false
    viewModel.windowNavigation.setHandlers(
      back: { navigateHistoryBack() },
      forward: { navigateHistoryForward() }
    )
    await Task.yield()
    await loadAgentPickerCatalogs()
    await reloadDecisions()
    await resolveInitialWorkspaceSelection()
    await Task.yield()
    guard !Task.isCancelled else {
      return
    }
    workspacePreparationComplete = true
    enableStartupFocusParticipation()
  }

  func refreshWorkspaceAfterDataChange(afterRefresh: Bool = false) {
    refreshDisplayState()
    repairInvalidRestoredSelectionIfNeeded()
    reconcileSheetState(afterRefresh: afterRefresh)
  }

  func handleSupervisorDecisionRefresh() {
    Task {
      await reloadDecisions()
      syncSupervisorDecisionRoute(recordHistory: false)
    }
  }

  func handleSupervisorLiveTickRefresh() async {
    await currentDecisionsRuntime.refreshLiveTick(from: store)
  }

  func handleSelectedTuiChange(
    _ selectedTuiID: String?,
    viewModel: ViewModel
  ) {
    guard let selectedTuiID else {
      return
    }
    if viewModel.selection.terminalID == selectedTuiID,
      let currentSize = selectedSessionTui?.size
    {
      syncTerminalResizeControls(to: currentSize)
      if viewModel.expectedSize == nil {
        viewModel.expectedSize = currentSize
      }
      enforceExpectedSize()
    }
  }

  func enableStartupFocusParticipation() {
    guard !startupFocusParticipationActive else {
      return
    }
    startupFocusParticipationActive = true
  }

  func repairInvalidRestoredSelectionIfNeeded() {
    let previousSelection = viewModel.selection
    guard let repairedSelection = repairedWorkspaceSelection(previousSelection) else {
      return
    }

    WorkspaceSelectionDefaults.clear()
    viewModel.suppressHistoryRecording = true
    viewModel.suppressNextSelectionChangeHandling = true
    viewModel.selection = repairedSelection
    WorkspaceSelectionDefaults.write(repairedSelection)
    updateNavigationState()

    Task {
      await handleSelectionChange(from: previousSelection, to: repairedSelection)
    }
  }

  private func repairedWorkspaceSelection(
    _ selection: WorkspaceSelection
  ) -> WorkspaceSelection? {
    guard shouldRepairWorkspaceSelection(selection) else {
      return nil
    }
    if selectionReferencesMissingSession(selection) {
      return fallbackWorkspaceSelection()
    }
    return repairWorkspaceSelectionTarget(selection)
  }

  private func repairWorkspaceSelectionTarget(
    _ selection: WorkspaceSelection
  ) -> WorkspaceSelection? {
    switch selection {
    case .create, .decisions:
      return nil
    case .decision(let sessionID, let decisionID):
      return repairSessionScopedSelection(sessionID, isPresent: hasDecision(decisionID))
    case .terminal(_, let terminalID):
      return hasTerminal(terminalID) ? nil : fallbackWorkspaceSelection()
    case .codex(_, let runID):
      return hasCodexRun(runID) ? nil : fallbackWorkspaceSelection()
    case .agent(let sessionID, let agentID):
      return repairAgentSelection(sessionID: sessionID, agentID: agentID)
    case .task(let sessionID, let taskID):
      return repairTaskSelection(sessionID: sessionID, taskID: taskID)
    }
  }

  private func shouldRepairWorkspaceSelection(_ selection: WorkspaceSelection) -> Bool {
    selection != .create && !store.sessionIndex.sessions.isEmpty
  }

  private func selectionReferencesMissingSession(_ selection: WorkspaceSelection) -> Bool {
    guard let sessionID = Self.normalizedCreateSessionAnchor(selection.sessionID) else {
      return false
    }
    return store.sessionIndex.sessionSummary(for: sessionID) == nil
  }

  private func repairSessionScopedSelection(
    _ sessionID: String?,
    isPresent: Bool
  ) -> WorkspaceSelection? {
    if selectionSessionMismatchesSelectedSession(sessionID) {
      return fallbackWorkspaceSelection()
    }
    return isPresent ? nil : fallbackWorkspaceSelection()
  }

  private func repairAgentSelection(sessionID: String?, agentID: String) -> WorkspaceSelection? {
    if selectionSessionMismatchesSelectedSession(sessionID) {
      return fallbackWorkspaceSelection()
    }
    guard let selectedSession = store.selectedSession else {
      return nil
    }
    return selectedSession.agents.contains(where: { $0.agentId == agentID })
      ? nil
      : fallbackWorkspaceSelection()
  }

  private func repairTaskSelection(sessionID: String?, taskID: String) -> WorkspaceSelection? {
    if selectionSessionMismatchesSelectedSession(sessionID) {
      return fallbackWorkspaceSelection()
    }
    guard let selectedSession = store.selectedSession else {
      return nil
    }
    return selectedSession.tasks.contains(where: { $0.taskId == taskID })
      ? nil
      : fallbackWorkspaceSelection()
  }

  private func selectionSessionMismatchesSelectedSession(_ sessionID: String?) -> Bool {
    guard let selectedSessionID = Self.normalizedCreateSessionAnchor(store.selectedSessionID),
      let sessionID = Self.normalizedCreateSessionAnchor(sessionID)
    else {
      return false
    }
    return sessionID != selectedSessionID
  }

  private func hasDecision(_ decisionID: String) -> Bool {
    decisionItems.contains(where: { $0.id == decisionID })
      || store.supervisorOpenDecisions.contains(where: { $0.id == decisionID })
  }

  private func hasTerminal(_ terminalID: String) -> Bool {
    selectedSessionTui != nil
      || store.selectedAgentTuis.contains(where: { $0.tuiId == terminalID })
      || displayState.sortedAgentTuis.contains(where: { $0.tuiId == terminalID })
  }

  private func hasCodexRun(_ runID: String) -> Bool {
    selectedCodexRun != nil
      || store.selectedCodexRuns.contains(where: { $0.runId == runID })
      || displayState.sortedCodexRuns.contains(where: { $0.runId == runID })
  }

  private func fallbackWorkspaceSelection() -> WorkspaceSelection {
    Self.initialSelection(
      displayState: displayState,
      selectedTerminalID: store.selectedAgentTui?.tuiId,
      selectedCodexRunID: store.selectedCodexRun?.runId
    )
  }
}
