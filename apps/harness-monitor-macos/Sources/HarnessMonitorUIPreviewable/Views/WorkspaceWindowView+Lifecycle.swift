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
    guard selection != .create else {
      return nil
    }
    guard !store.sessionIndex.sessions.isEmpty else {
      return nil
    }
    if let sessionID = Self.normalizedCreateSessionAnchor(selection.sessionID),
      store.sessionIndex.sessionSummary(for: sessionID) == nil
    {
      return fallbackWorkspaceSelection()
    }

    switch selection {
    case .create, .decisions:
      return nil
    case .decision(let sessionID, let decisionID):
      if let selectedSessionID = Self.normalizedCreateSessionAnchor(store.selectedSessionID),
        let sessionID = Self.normalizedCreateSessionAnchor(sessionID),
        sessionID != selectedSessionID
      {
        return fallbackWorkspaceSelection()
      }
      let hasDecision =
        decisionItems.contains(where: { $0.id == decisionID })
        || store.supervisorOpenDecisions.contains(where: { $0.id == decisionID })
      return hasDecision ? nil : fallbackWorkspaceSelection()
    case .terminal(_, let terminalID):
      let hasTerminal =
        selectedSessionTui != nil
        || store.selectedAgentTuis.contains(where: { $0.tuiId == terminalID })
        || displayState.sortedAgentTuis.contains(where: { $0.tuiId == terminalID })
      return hasTerminal ? nil : fallbackWorkspaceSelection()
    case .codex(_, let runID):
      let hasRun =
        selectedCodexRun != nil
        || store.selectedCodexRuns.contains(where: { $0.runId == runID })
        || displayState.sortedCodexRuns.contains(where: { $0.runId == runID })
      return hasRun ? nil : fallbackWorkspaceSelection()
    case .agent(let sessionID, let agentID):
      if let selectedSessionID = Self.normalizedCreateSessionAnchor(store.selectedSessionID),
        let sessionID = Self.normalizedCreateSessionAnchor(sessionID),
        sessionID != selectedSessionID
      {
        return fallbackWorkspaceSelection()
      }
      guard let selectedSession = store.selectedSession else {
        return nil
      }
      return selectedSession.agents.contains(where: { $0.agentId == agentID })
        ? nil
        : fallbackWorkspaceSelection()
    case .task(let sessionID, let taskID):
      if let selectedSessionID = Self.normalizedCreateSessionAnchor(store.selectedSessionID),
        let sessionID = Self.normalizedCreateSessionAnchor(sessionID),
        sessionID != selectedSessionID
      {
        return fallbackWorkspaceSelection()
      }
      guard let selectedSession = store.selectedSession else {
        return nil
      }
      return selectedSession.tasks.contains(where: { $0.taskId == taskID })
        ? nil
        : fallbackWorkspaceSelection()
    }
  }

  private func fallbackWorkspaceSelection() -> WorkspaceSelection {
    Self.initialSelection(
      displayState: displayState,
      selectedTerminalID: store.selectedAgentTui?.tuiId,
      selectedCodexRunID: store.selectedCodexRun?.runId
    )
  }
}
