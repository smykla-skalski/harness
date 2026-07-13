import HarnessMonitorKit
import SwiftUI

/// Navigates from a dispatched board item to the live session that hosts its
/// spawned managed agent. Selects the session, raises its window, and focuses
/// the linked work item so the operator lands inside the running session
/// instead of the modal task-actions sheet. Focusing a specific codex run or
/// agent by id is not possible client-side today: the dispatch summary and the
/// codex-run snapshot carry no `workItemId -> runId` link, so the work item is
/// the closest real anchor the window can resolve.
@MainActor
enum TaskBoardSpawnedSessionNavigator {
  static func open(
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction,
    sessionID: String,
    workItemID: String?
  ) {
    if let workItemID, !workItemID.isEmpty {
      store.requestSessionRoute(.task(sessionID: sessionID, taskID: workItemID))
    }
    openWindow.openHarnessSessionWindow(sessionID: sessionID)
    Task { @MainActor in
      await store.selectSession(sessionID)
    }
  }
}
