import HarnessMonitorKit
import SwiftUI

/// Navigates from a dispatched board item to the live session that hosts its
/// spawned managed agent. Selects the session, raises its window, and focuses
/// the linked work item so the operator lands inside the running session
/// instead of the modal task-actions sheet. When dispatch delivery returns the
/// managed-agent snapshot, the route focuses that exact run; older call sites
/// continue to fall back to the linked work item.
@MainActor
enum TaskBoardSpawnedSessionNavigator {
  static func open(
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction,
    sessionID: String,
    workItemID: String?,
    managedAgent: ManagedAgentSnapshot? = nil
  ) {
    if let managedAgent {
      switch managedAgent {
      case .terminal(let snapshot):
        store.requestSessionRoute(.terminal(sessionID: sessionID, terminalID: snapshot.tuiId))
      case .codex(let snapshot):
        store.requestSessionRoute(.codex(sessionID: sessionID, runID: snapshot.runId))
      case .acp(let snapshot):
        store.requestSessionRoute(.agent(sessionID: sessionID, agentID: snapshot.acpId))
      }
    } else if let workItemID, !workItemID.isEmpty {
      store.requestSessionRoute(.task(sessionID: sessionID, taskID: workItemID))
    }
    openWindow.openHarnessSessionWindow(sessionID: sessionID)
    Task { @MainActor in
      await store.selectSession(sessionID)
    }
  }
}
