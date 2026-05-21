import HarnessMonitorKit
import SwiftUI

extension DecisionDeskPreviewView {
  func snoozeAllCritical() async {
    let handler = actionHandler
    let oneHour: TimeInterval = 60 * 60
    for id in criticalDecisionIDs {
      await handler.snooze(decisionID: id, duration: oneHour)
    }
  }

  func syncSelectionFromStoreIfNeeded() {
    guard let requestedID = store?.supervisorSelectedDecisionID else {
      return
    }
    if selection == nil || selection != requestedID {
      selection = requestedID
    }
  }

  func dismissAllInfo() async {
    let handler = actionHandler
    for id in infoDecisionIDs {
      await handler.dismiss(decisionID: id)
    }
  }

  func dismissSelected() async {
    guard let selection else {
      return
    }
    await actionHandler.dismiss(decisionID: selection)
  }

  func beginDismissAllVisible() {
    let ids = visibleOpenDecisionIDs
    guard !ids.isEmpty else {
      return
    }
    pendingDismissBatch = DecisionDismissBatchSnapshot(
      ids: ids,
      count: ids.count,
      filterSignature: visibleSnapshot.signature,
      scopeDescription: decisionWorkspaceScope.scopeDescription,
      capturedAt: Date()
    )
    dismissAllVisibleDraft = ""
    showDismissAllVisibleConfirmation = true
  }

  var dismissConfirmationMessage: String {
    guard let snapshot = pendingDismissBatch else {
      return "No visible decisions to dismiss"
    }
    let capturedAt = snapshot.capturedAt.formatted(
      date: .abbreviated,
      time: .standard
    )
    return "Scope: \(snapshot.scopeDescription)\nCaptured: \(capturedAt)"
  }

  func confirmDismissAllVisible() async {
    guard let snapshot = pendingDismissBatch else {
      return
    }
    guard dismissAllVisibleDraft == "\(snapshot.count)" else {
      store?.presentFailureFeedback("Typed count did not match")
      return
    }
    let currentIDs = visibleOpenDecisionIDs
    guard currentIDs == snapshot.ids, visibleSnapshot.signature == snapshot.filterSignature else {
      store?.presentFailureFeedback("Visible decisions changed. Bulk dismiss aborted")
      return
    }
    let handler = actionHandler
    for id in snapshot.ids {
      await handler.dismiss(decisionID: id)
    }
    reopenBatch = DecisionReopenBatchState(
      ids: snapshot.ids,
      expiresAt: Date().addingTimeInterval(15)
    )
    pendingDismissBatch = nil
    dismissAllVisibleDraft = ""
  }

  func reopenDismissedBatch(_ batch: DecisionReopenBatchState) async {
    guard Date() <= batch.expiresAt else {
      store?.presentFailureFeedback("Recovery window expired")
      reopenBatch = nil
      return
    }
    guard let decisionStore = store?.supervisorDecisionStore else {
      store?.presentFailureFeedback("Cannot reopen dismissed batch: decision store unavailable")
      return
    }
    for id in batch.ids {
      do {
        switch try await decisionStore.reopen(id: id) {
        case .reopened:
          break
        case .missing:
          store?.presentFailureFeedback("Cannot reopen \(id): decision missing")
        case .notDismissed:
          store?.presentFailureFeedback("Cannot reopen \(id): decision state changed")
        }
      } catch {
        store?.presentFailureFeedback(
          "Failed to reopen \(id): \(error.localizedDescription)"
        )
      }
    }
  }

  func reload() async {
    await runtime.reload(from: store)
    await rebuildPresentation()

    if let requestedID = store?.supervisorSelectedDecisionID,
      runtime.decisions.contains(where: { $0.id == requestedID })
    {
      selection = requestedID
      return
    }

    if let selection, runtime.decisions.contains(where: { $0.id == selection }) {
      return
    }

    let firstDecisionID = runtime.decisions.first?.id
    selection = firstDecisionID
    store?.supervisorSelectedDecisionID = firstDecisionID
  }

  @MainActor
  func syncSelectedDecisionViewModel() async {
    guard let selectedDecision, let input = selectedDecisionPreparationInput else {
      if cachedDetailViewModel != nil {
        cachedDetailViewModel = nil
        cachedDetailViewModelInput = nil
      }
      return
    }
    guard
      cachedDetailViewModel?.decision.id != selectedDecision.id
        || cachedDetailViewModelInput != input
    else {
      return
    }
    let preparedContent = await decisionDeskDetailPreparationWorker.prepare(input: input)
    guard !Task.isCancelled else {
      return
    }
    cachedDetailViewModel = DecisionDetailViewModel(
      decision: selectedDecision,
      handler: actionHandler,
      preparedContent: preparedContent
    )
    cachedDetailViewModelInput = input
  }

  @MainActor
  func rebuildPresentation() async {
    presentationGeneration &+= 1
    let generation = presentationGeneration
    let input = DecisionsSidebarPresentationInput(
      items: runtime.decisionItems,
      filters: sidebarFilters
    )
    let presentation = await presentationWorker.compute(input: input)
    guard !Task.isCancelled, presentationGeneration == generation else {
      return
    }
    if cachedPresentation != presentation {
      cachedPresentation = presentation
    }
  }
}
