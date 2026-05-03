import HarnessMonitorKit
import SwiftUI

struct WorkspaceDecisionReloadRepair: Equatable {
  let selection: WorkspaceSelection?
  let supervisorSelectedDecisionID: String?
}

extension WorkspaceWindowView {
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
      viewModel.createSessionID = sessionID
      await store.selectSession(sessionID)
    } else if let sessionID = newValue.sessionID {
      viewModel.createSessionID = sessionID
    } else if case .create = newValue, let previousSessionID = oldValue.sessionID {
      viewModel.createSessionID = previousSessionID
      if store.selectedSessionID == nil {
        await store.selectSession(previousSessionID)
      }
    }

    if !oldValue.isDecisionRoute, newValue.isDecisionRoute {
      restoreDecisionInspectorForDecisionRoute()
    }

    switch newValue {
    case .decision(_, let decisionID):
      handleDecisionSelectionChange(from: oldValue, decisionID: decisionID)
    case .terminal(_, let terminalID):
      hideDecisionInspectorForNonDecisionRoute()
      handleTerminalSelectionChange(from: oldValue, terminalID: terminalID)
    case .codex(_, let runID):
      hideDecisionInspectorForNonDecisionRoute()
      handleCodexSelectionChange(from: oldValue, runID: runID)
    case .create, .agent, .task:
      hideDecisionInspectorForNonDecisionRoute()
      store.supervisorSelectedDecisionID = nil
    case .decisions:
      store.supervisorSelectedDecisionID = nil
    }
  }

  func reloadDecisions() async {
    let previousSelection = viewModel.selection
    let previousVisibleDecisionIDs = cachedDecisionWorkspaceSnapshot.visibleDecisionIDs
    let requestedDecisionID = store.supervisorSelectedDecisionID
    await currentDecisionsRuntime.reload(from: store)
    refreshDecisionWorkspaceSnapshot()
    reconcileDecisionRouteAfterReload(
      previousSelection: previousSelection,
      previousVisibleDecisionIDs: previousVisibleDecisionIDs,
      requestedDecisionID: requestedDecisionID
    )
  }

  func refreshDecisionWorkspaceSnapshot() {
    let nextSnapshot = DecisionWorkspaceScope(
      decisions: decisionItems,
      filters: currentDecisionFilters
    )
    replaceDecisionWorkspaceSnapshot(nextSnapshot)
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
    return "Scope: \(snapshot.scopeDescription)\nCaptured: \(capturedAt)"
  }

  func beginDismissAllVisible() {
    let ids = decisionWorkspaceScope.visibleDecisionIDs
    guard !ids.isEmpty else {
      return
    }

    currentPendingDismissBatch = DismissBatchSnapshot(
      ids: ids,
      count: ids.count,
      filterSignature: decisionWorkspaceScope.visibleSnapshot.signature,
      scopeDescription: decisionWorkspaceScope.scopeDescription,
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

    let currentIDs = decisionWorkspaceScope.visibleDecisionIDs
    guard
      currentIDs == snapshot.ids,
      decisionWorkspaceScope.visibleSnapshot.signature == snapshot.filterSignature
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
    await refreshDecisionWorkspaceAfterMutation()
  }

  func dismissSelectedDecision() async {
    guard let decisionID = selectedDecision?.id else {
      return
    }
    await decisionActionHandler.dismiss(decisionID: decisionID)
    await refreshDecisionWorkspaceAfterMutation()
  }

  func dismissAllInfo() async {
    for id in infoDecisionIDs {
      await decisionActionHandler.dismiss(decisionID: id)
    }
    await refreshDecisionWorkspaceAfterMutation()
  }

  func snoozeAllCritical() async {
    let oneHour: TimeInterval = 60 * 60
    for id in criticalDecisionIDs {
      await decisionActionHandler.snooze(decisionID: id, duration: oneHour)
    }
    await refreshDecisionWorkspaceAfterMutation()
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
    await refreshDecisionWorkspaceAfterMutation()
  }

  func refreshDecisionWorkspaceAfterMutation() async {
    await reloadDecisions()
    syncSupervisorDecisionRoute(recordHistory: false)
  }

  func reconcileDecisionRouteAfterReload(
    previousSelection: WorkspaceSelection,
    previousVisibleDecisionIDs: [String],
    requestedDecisionID: String?
  ) {
    guard
      let repair = Self.repairedDecisionSelectionAfterReload(
        previousSelection: previousSelection,
        previousVisibleDecisionIDs: previousVisibleDecisionIDs,
        requestedDecisionID: requestedDecisionID,
        currentScope: decisionWorkspaceScope,
        fallbackSessionID: store.selectedSessionID
      )
    else {
      return
    }

    if let selection = repair.selection {
      applyProgrammaticSelection(selection, recordHistory: false)
    }
    if store.supervisorSelectedDecisionID != repair.supervisorSelectedDecisionID {
      store.supervisorSelectedDecisionID = repair.supervisorSelectedDecisionID
    }
  }

  static func repairedDecisionSelectionAfterReload(
    previousSelection: WorkspaceSelection,
    previousVisibleDecisionIDs: [String],
    requestedDecisionID: String?,
    currentScope: DecisionWorkspaceScope,
    fallbackSessionID: String?
  ) -> WorkspaceDecisionReloadRepair? {
    let decisionsByID = Dictionary(uniqueKeysWithValues: currentScope.decisions.map { ($0.id, $0) })

    // Keep an explicit surviving external request first. Otherwise, if the
    // requested route went stale but the currently displayed decision survived,
    // re-synchronize the store back to the current detail route. Only then do
    // we repair by visible-list order or fall back to the desk.
    if let previousDecisionID = previousSelection.decisionID,
      let requestedDecisionID,
      previousDecisionID != requestedDecisionID,
      let requestedDecision = decisionsByID[requestedDecisionID]
    {
      return WorkspaceDecisionReloadRepair(
        selection: .decision(
          sessionID: requestedDecision.sessionID,
          decisionID: requestedDecisionID
        ),
        supervisorSelectedDecisionID: requestedDecisionID
      )
    }

    if let previousDecisionID = previousSelection.decisionID,
      let requestedDecisionID,
      previousDecisionID != requestedDecisionID,
      decisionsByID[requestedDecisionID] == nil,
      let previousDecision = decisionsByID[previousDecisionID]
    {
      return WorkspaceDecisionReloadRepair(
        selection: .decision(
          sessionID: previousDecision.sessionID,
          decisionID: previousDecisionID
        ),
        supervisorSelectedDecisionID: previousDecisionID
      )
    }

    guard let missingDecisionID = previousSelection.decisionID ?? requestedDecisionID,
      decisionsByID[missingDecisionID] == nil
    else {
      return nil
    }

    guard previousSelection.decisionID != nil else {
      return WorkspaceDecisionReloadRepair(
        selection: nil,
        supervisorSelectedDecisionID: nil
      )
    }

    guard
      let replacementDecisionID = nextVisibleDecisionID(
        afterRemoving: missingDecisionID,
        previousVisibleDecisionIDs: previousVisibleDecisionIDs,
        currentVisibleDecisionIDs: currentScope.visibleDecisionIDs
      ),
      let replacementDecision = decisionsByID[replacementDecisionID]
    else {
      return WorkspaceDecisionReloadRepair(
        selection: .decisions(sessionID: previousSelection.sessionID ?? fallbackSessionID),
        supervisorSelectedDecisionID: nil
      )
    }

    return WorkspaceDecisionReloadRepair(
      selection: .decision(
        sessionID: replacementDecision.sessionID,
        decisionID: replacementDecisionID
      ),
      supervisorSelectedDecisionID: replacementDecisionID
    )
  }

  static func nextVisibleDecisionID(
    afterRemoving removedDecisionID: String,
    previousVisibleDecisionIDs: [String],
    currentVisibleDecisionIDs: [String]
  ) -> String? {
    guard !currentVisibleDecisionIDs.isEmpty else {
      return nil
    }

    let currentVisibleDecisionSet = Set(currentVisibleDecisionIDs)
    if let removedIndex = previousVisibleDecisionIDs.firstIndex(of: removedDecisionID) {
      for candidateID in previousVisibleDecisionIDs[(removedIndex + 1)...]
      where currentVisibleDecisionSet.contains(candidateID) {
        return candidateID
      }
      for candidateID in previousVisibleDecisionIDs[..<removedIndex].reversed()
      where currentVisibleDecisionSet.contains(candidateID) {
        return candidateID
      }
    }

    return currentVisibleDecisionIDs.first
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
