import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
  var resolvedCreateSessionID: String? {
    viewModel.selection.sessionID ?? viewModel.createSessionID ?? store.selectedSessionID
  }

  var createPaneSessionActionUnavailableNote: String? {
    store.sessionActionUnavailableMessage(sessionID: resolvedCreateSessionID)
  }

  var decisionWorkspaceScope: DecisionWorkspaceScope {
    let snapshot = cachedDecisionWorkspaceSnapshot
    return DecisionWorkspaceScope(
      decisions: snapshot.decisions,
      filters: snapshot.filters,
      visibleSnapshot: snapshot.visibleSnapshot,
      selectedDecisionID: viewModel.selection.decisionID
    )
  }

  var selectedSessionTui: AgentTuiSnapshot? {
    guard let selectedTuiID = viewModel.selection.terminalID else {
      return nil
    }
    if viewModel.hasFreshManagedAgentTuis,
      let selectedTui = store.selectedAgentTui,
      selectedTui.tuiId == selectedTuiID
    {
      return selectedTui
    }
    return displayState.sortedAgentTuis.first { $0.tuiId == selectedTuiID }
  }

  var selectedCodexRun: CodexRunSnapshot? {
    guard let selectedRunID = viewModel.selection.codexRunID else {
      return nil
    }
    if viewModel.hasFreshManagedCodexRuns,
      let selectedRun = store.selectedCodexRun,
      selectedRun.runId == selectedRunID
    {
      return selectedRun
    }
    return displayState.sortedCodexRuns.first { $0.runId == selectedRunID }
  }

  var selectedDecision: Decision? {
    decisionWorkspaceScope.selectedDecision
  }

  var trimmedInput: String {
    viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedCodexPrompt: String {
    viewModel.codexPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedCodexContext: String {
    viewModel.codexContext.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedProjectDir: String? {
    let normalized = viewModel.projectDir.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  var parsedArgvOverride: [String] {
    viewModel.argvOverride
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  var canStartCodex: Bool {
    createPaneSessionActionUnavailableNote == nil
      && !viewModel.isSubmitting
      && !trimmedCodexPrompt.isEmpty
  }

  var canSend: Bool {
    guard let selectedSessionTui else {
      return false
    }
    return selectedSessionTui.status.isActive && !trimmedInput.isEmpty && !viewModel.isSubmitting
  }

  var canResize: Bool {
    guard let selectedSessionTui else {
      return false
    }
    return selectedSessionTui.status.isActive && viewModel.rows > 0 && viewModel.cols > 0
      && !viewModel.isSubmitting
  }

  var canStop: Bool {
    selectedSessionTui?.status.isActive == true && !viewModel.isSubmitting
  }

  var canSteerCodex: Bool {
    guard let selectedCodexRun else {
      return false
    }
    return
      selectedCodexRun.status.isActive
      && !trimmedCodexContext.isEmpty
      && !viewModel.isSubmitting
  }

  var usesLiveViewportSplitLayout: Bool {
    selectedSessionTui?.status.isActive == true
  }

  var liveViewportIsReconciling: Bool {
    guard let selectedSessionTui, selectedSessionTui.status.isActive else {
      return false
    }
    if viewModel.pendingViewportResizeTarget != nil {
      return true
    }
    guard let expectedSize = viewModel.expectedSize else {
      return false
    }
    return selectedSessionTui.size != expectedSize
  }

  var selectedCodexApprovalItems: [CodexApprovalItem] {
    guard let selectedCodexRun else {
      return []
    }
    return Self.codexApprovalItems(for: selectedCodexRun, decisions: store.supervisorOpenDecisions)
  }

  var decisionActionHandler: any DecisionActionHandler {
    store.supervisorDecisionActionHandler()
  }

  var sessionObserver: ObserverSummary? {
    store.selectedSession?.observer
  }

  var visibleDecisionSnapshot: DecisionsSidebarViewModel.VisibleSnapshot {
    decisionWorkspaceScope.visibleSnapshot
  }

  var visibleOpenDecisionIDs: [String] {
    decisionWorkspaceScope.visibleDecisionIDs
  }

  var criticalDecisionIDs: [String] {
    decisionWorkspaceScope.visibleCriticalDecisionIDs
  }

  var infoDecisionIDs: [String] {
    decisionWorkspaceScope.visibleInfoDecisionIDs
  }
}
