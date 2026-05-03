import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
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
}
