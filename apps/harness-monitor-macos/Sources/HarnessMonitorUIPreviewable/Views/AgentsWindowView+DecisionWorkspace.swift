import HarnessMonitorKit
import SwiftUI

extension AgentsWindowView {
  func focusDecisionDesk() {
    applyProgrammaticSelection(
      .decisions(sessionID: store.selectedSessionID),
      recordHistory: true
    )
    currentDecisionDetailTab = .context
  }

  func focusPrimaryDecisionAction() {
    syncSupervisorDecisionRoute(recordHistory: true)
    currentDecisionDetailTab = .context
  }

  func handleViewSelectionChange(
    from oldValue: WorkspaceSelection,
    to newValue: WorkspaceSelection,
    viewModel: ViewModel
  ) {
    if oldValue != newValue {
      cancelPendingViewportResize()
      Task {
        await flushPendingKeySequenceIfNeeded()
      }
    }

    if viewModel.suppressHistoryRecording {
      viewModel.suppressHistoryRecording = false
    } else if oldValue != newValue {
      viewModel.navigationBackStack.append(oldValue)
      viewModel.navigationForwardStack.removeAll()
      updateNavigationState()
    }

    if !newValue.isDecisionRoute {
      isDecisionInspectorVisible = false
    }

    Task {
      await handleSelectionChange(from: oldValue, to: newValue)
    }
  }

  func handleWindowDisappear() {
    cancelPendingViewportResize()
    Task {
      await flushPendingKeySequenceIfNeeded()
    }
    navigationBridge.update(WindowNavigationState())
  }

  func handleSelectionChange(
    from oldValue: WorkspaceSelection,
    to newValue: WorkspaceSelection
  ) async {
    if let sessionID = newValue.sessionID, sessionID != store.selectedSessionID {
      await store.selectSession(sessionID)
    }

    switch newValue {
    case .decision(_, let decisionID):
      handleDecisionSelectionChange(from: oldValue, decisionID: decisionID)
    case .terminal(_, let terminalID):
      handleTerminalSelectionChange(from: oldValue, terminalID: terminalID)
    case .codex(_, let runID):
      handleCodexSelectionChange(from: oldValue, runID: runID)
    case .create, .decisions, .agent, .task:
      store.supervisorSelectedDecisionID = nil
    }
  }

  func reloadDecisions() async {
    await currentDecisionsRuntime.reload(from: store)
    if viewModel.selection.isDecisionRoute,
      viewModel.selection.decisionID != nil,
      selectedDecision == nil
    {
      applyProgrammaticSelection(
        .decisions(sessionID: viewModel.selection.sessionID ?? store.selectedSessionID),
        recordHistory: false
      )
    }
  }

  func syncSupervisorDecisionRoute(recordHistory: Bool) {
    guard let requestedID = store.supervisorSelectedDecisionID else {
      return
    }

    let sessionID =
      decisionItems.first(where: { $0.id == requestedID })?.sessionID
      ?? store.supervisorOpenDecisions.first(where: { $0.id == requestedID })?.sessionID
    applyProgrammaticSelection(
      .decision(sessionID: sessionID, decisionID: requestedID),
      recordHistory: recordHistory
    )
  }

  var dismissConfirmationMessage: String {
    guard let snapshot = currentPendingDismissBatch else {
      return "No visible decisions to dismiss."
    }

    let capturedAt = snapshot.capturedAt.formatted(
      date: .abbreviated,
      time: .standard
    )
    return "Scope: \(snapshot.filterSignature)\nCaptured: \(capturedAt)"
  }

  func beginDismissAllVisible() {
    let ids = visibleOpenDecisionIDs
    guard !ids.isEmpty else {
      return
    }

    currentPendingDismissBatch = DismissBatchSnapshot(
      ids: ids,
      count: ids.count,
      filterSignature: visibleDecisionSnapshot.signature,
      capturedAt: Date()
    )
    dismissAllVisibleDraftText = ""
    showsDismissAllVisibleConfirmation = true
  }

  func confirmDismissAllVisible() async {
    guard let snapshot = currentPendingDismissBatch else {
      return
    }
    guard dismissAllVisibleDraftText == "\(snapshot.count)" else {
      store.presentFailureFeedback("Typed count did not match.")
      return
    }

    let currentIDs = visibleOpenDecisionIDs
    guard
      currentIDs == snapshot.ids,
      visibleDecisionSnapshot.signature == snapshot.filterSignature
    else {
      store.presentFailureFeedback("Visible decisions changed. Bulk dismiss aborted.")
      return
    }

    for id in snapshot.ids {
      await decisionActionHandler.dismiss(decisionID: id)
    }
    currentReopenBatch = ReopenBatchState(
      ids: snapshot.ids,
      expiresAt: Date().addingTimeInterval(15)
    )
    currentPendingDismissBatch = nil
    dismissAllVisibleDraftText = ""
  }

  func dismissSelectedDecision() async {
    guard let decisionID = selectedDecision?.id else {
      return
    }
    await decisionActionHandler.dismiss(decisionID: decisionID)
  }

  func dismissAllInfo() async {
    for id in infoDecisionIDs {
      await decisionActionHandler.dismiss(decisionID: id)
    }
  }

  func snoozeAllCritical() async {
    let oneHour: TimeInterval = 60 * 60
    for id in criticalDecisionIDs {
      await decisionActionHandler.snooze(decisionID: id, duration: oneHour)
    }
  }

  func reopenDismissedBatch(_ batch: ReopenBatchState) async {
    guard Date() <= batch.expiresAt else {
      store.presentFailureFeedback("Recovery window expired.")
      currentReopenBatch = nil
      return
    }
    guard let decisionStore = store.supervisorDecisionStore else {
      store.presentFailureFeedback("Cannot reopen dismissed batch: decision store unavailable.")
      return
    }

    for id in batch.ids {
      do {
        guard let decision = try await decisionStore.decision(id: id) else {
          store.presentFailureFeedback("Cannot reopen \(id): decision missing.")
          continue
        }
        guard decision.statusRaw == "dismissed" else {
          store.presentFailureFeedback("Cannot reopen \(id): decision state changed.")
          continue
        }

        decision.statusRaw = "open"
        decision.resolutionJSON = nil
      } catch {
        store.presentFailureFeedback("Failed to reopen \(id): \(error.localizedDescription)")
      }
    }
  }

  private func handleDecisionSelectionChange(
    from oldValue: WorkspaceSelection,
    decisionID: String
  ) {
    guard oldValue.decisionID != decisionID else {
      return
    }
    store.supervisorSelectedDecisionID = decisionID
  }

  private func handleTerminalSelectionChange(
    from oldValue: WorkspaceSelection,
    terminalID: String
  ) {
    store.supervisorSelectedDecisionID = nil
    guard oldValue.terminalID != terminalID else {
      return
    }

    store.selectAgentTui(tuiID: terminalID)
    if let currentSize = selectedSessionTui?.size {
      syncTerminalResizeControls(to: currentSize)
      viewModel.expectedSize = currentSize
    }
    enforceExpectedSize()
  }

  private func handleCodexSelectionChange(
    from oldValue: WorkspaceSelection,
    runID: String
  ) {
    store.supervisorSelectedDecisionID = nil
    guard oldValue.codexRunID != runID else {
      return
    }
    store.selectCodexRun(runID: runID)
  }
}
