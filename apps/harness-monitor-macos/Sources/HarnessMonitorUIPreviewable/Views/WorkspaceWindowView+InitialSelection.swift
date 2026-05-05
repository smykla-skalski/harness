import HarnessMonitorKit

extension WorkspaceWindowView {
  static func initialWindowSelection(
    store: HarnessMonitorStore,
    displayState: AgentTuiDisplayState,
    pendingRequest: HarnessMonitorStore.PendingWorkspaceSelectionRequest?
  ) -> WorkspaceSelection {
    if let pendingRequest {
      return pendingRequest.selection
    }
    if let restoredSelection = restoredInitialSelection(store: store, displayState: displayState) {
      return restoredSelection
    }
    return initialSelection(
      displayState: displayState,
      selectedTerminalID: store.selectedAgentTui?.tuiId,
      selectedCodexRunID: store.selectedCodexRun?.runId
    )
  }

  private static func restoredInitialSelection(
    store: HarnessMonitorStore,
    displayState: AgentTuiDisplayState
  ) -> WorkspaceSelection? {
    guard let selection = WorkspaceSelectionDefaults.read() else {
      return nil
    }

    switch selection {
    case .create, .decisions, .decision, .agent, .task:
      return selection
    case .terminal(_, let terminalID):
      guard
        let terminal =
          displayState.sortedAgentTuis.first(where: { $0.tuiId == terminalID })
          ?? store.selectedAgentTuis.first(where: { $0.tuiId == terminalID && !$0.status.isActive })
      else {
        return nil
      }
      return .terminal(sessionID: terminal.sessionId, terminalID: terminalID)
    case .codex(_, let runID):
      guard
        let run =
          displayState.sortedCodexRuns.first(where: { $0.runId == runID })
          ?? store.selectedCodexRuns.first(where: { $0.runId == runID && !$0.status.isActive })
      else {
        return nil
      }
      return .codex(sessionID: run.sessionId, runID: runID)
    }
  }
}
