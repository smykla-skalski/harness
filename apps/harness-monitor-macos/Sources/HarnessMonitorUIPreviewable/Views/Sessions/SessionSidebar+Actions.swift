import HarnessMonitorKit
import SwiftUI

extension SessionSidebar {
  func linkTask(_ taskID: String, to decisionID: String) {
    state.lastTaskDecisionLink = SessionTaskDecisionLink(
      sessionID: state.sessionID,
      taskID: taskID,
      decisionID: decisionID
    )
  }

  func dismissDecisions(_ ids: [String]) {
    guard !ids.isEmpty else { return }
    state.decisionBulkActions.recordDismissedBatch(ids, undoManager: undoManager)
    let bulkActions = state.decisionBulkActions
    let toast = SessionDecisionUndoToastState(decisionIDs: ids)
    store.toast.enqueueUndoable(
      "\(toast.dismissedCopy). \(SessionDecisionUndoToastState.commitBarrierCopy)",
      accessibilityIdentifier: HarnessMonitorAccessibility.sessionWindowDismissUndoToast
    ) { @MainActor in
      bulkActions.reopenRequestedBatch = ids
    }
    Task {
      let handler = store.supervisorDecisionActionHandler()
      for id in ids {
        await handler.dismiss(decisionID: id)
      }
    }
  }

  func reopenDecisionBatch(_ ids: [String]) async {
    guard let decisionStore = store.supervisorDecisionStore else { return }
    for id in ids {
      _ = try? await decisionStore.reopen(id: id)
    }
  }

  func severityShape(for status: AgentStatus) -> SessionSidebarSeverityShape {
    switch status {
    case .active: .dot
    case .awaitingReview: .alert
    case .idle: .none
    case .disconnected, .removed: .ring
    }
  }

  func severityTint(for status: AgentStatus) -> Color {
    switch status {
    case .active, .awaitingReview: .accentColor
    case .idle, .disconnected, .removed: .gray
    }
  }

  func severityShape(for severity: TaskSeverity) -> SessionSidebarSeverityShape {
    switch severity {
    case .low: .none
    case .medium: .dot
    case .high: .ring
    case .critical: .alert
    }
  }

  func severityTint(for severity: TaskSeverity) -> Color {
    switch severity {
    case .low: .gray
    case .medium, .high, .critical: .accentColor
    }
  }

  func severityShape(for severity: DecisionSeverity?) -> SessionSidebarSeverityShape {
    switch severity {
    case .info: .dot
    case .warn: .ring
    case .needsUser, .critical: .alert
    case .none: .none
    }
  }

  func severityTint(for severity: DecisionSeverity?) -> Color {
    switch severity {
    case .info, .none: .gray
    case .warn, .needsUser, .critical: .accentColor
    }
  }
}
