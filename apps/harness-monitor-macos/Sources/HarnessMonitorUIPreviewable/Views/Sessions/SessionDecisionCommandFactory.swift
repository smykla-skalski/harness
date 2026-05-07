import Foundation
import HarnessMonitorKit

@MainActor
enum SessionDecisionCommandFactory {
  static func make(
    store: HarnessMonitorStore,
    state: SessionWindowStateCache,
    visibleDecisions: [Decision],
    undoManager: UndoManager?
  ) -> SessionDecisionCommand {
    let selectedIDs = Array(state.sidebarSelection.selectedDecisionIDs)
    let visibleIDs = visibleDecisions.map(\.id)
    let reopenIDs = state.decisionBulkActions.lastDismissedBatch

    return SessionDecisionCommand(
      sessionID: state.sessionID,
      canDismissSelected: !selectedIDs.isEmpty,
      canDismissVisible: !visibleIDs.isEmpty,
      canReopenBatch: !reopenIDs.isEmpty,
      dismissSelected: {
        Task { @MainActor in
          dismiss(ids: selectedIDs, store: store, state: state, undoManager: undoManager)
        }
      },
      dismissVisible: {
        Task { @MainActor in
          dismiss(ids: visibleIDs, store: store, state: state, undoManager: undoManager)
        }
      },
      reopenBatch: {
        Task { @MainActor in
          await reopen(ids: reopenIDs, store: store)
        }
      }
    )
  }

  private static func dismiss(
    ids: [String],
    store: HarnessMonitorStore,
    state: SessionWindowStateCache,
    undoManager: UndoManager?
  ) {
    guard !ids.isEmpty else { return }
    state.decisionBulkActions.recordDismissedBatch(ids, undoManager: undoManager)
    Task {
      let handler = store.supervisorDecisionActionHandler()
      for id in ids {
        await handler.dismiss(decisionID: id)
      }
    }
  }

  private static func reopen(ids: [String], store: HarnessMonitorStore) async {
    guard let decisionStore = store.supervisorDecisionStore else { return }
    for id in ids {
      _ = try? await decisionStore.reopen(id: id)
    }
  }
}
