import HarnessMonitorKit
import SwiftUI

extension AgentsWindowView {
  var selectedSessionTui: AgentTuiSnapshot? {
    guard let selectedTuiID = viewModel.selection.terminalID else {
      return nil
    }
    return displayState.sortedAgentTuis.first { $0.tuiId == selectedTuiID }
  }

  var selectedCodexRun: CodexRunSnapshot? {
    guard let selectedRunID = viewModel.selection.codexRunID else {
      return nil
    }
    return displayState.sortedCodexRuns.first { $0.runId == selectedRunID }
  }

  var selectedDecision: Decision? {
    guard let selectedDecisionID = viewModel.selection.decisionID else {
      return nil
    }
    return decisionItems.first { $0.id == selectedDecisionID }
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
    !viewModel.isSubmitting && !trimmedCodexPrompt.isEmpty
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
    DecisionsSidebarViewModel.visibleSnapshot(
      decisions: decisionItems,
      filters: currentDecisionFilters
    )
  }

  var visibleOpenDecisionIDs: [String] {
    visibleDecisionSnapshot.decisionIDs
  }

  var criticalDecisionIDs: [String] {
    decisionItems
      .filter { $0.severityRaw == DecisionSeverity.critical.rawValue }
      .map(\.id)
  }

  var infoDecisionIDs: [String] {
    decisionItems
      .filter { $0.severityRaw == DecisionSeverity.info.rawValue }
      .map(\.id)
  }
}
