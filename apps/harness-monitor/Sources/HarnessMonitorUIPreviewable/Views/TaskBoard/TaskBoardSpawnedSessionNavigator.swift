import HarnessMonitorKit
import SwiftUI

/// Navigates from a dispatched board item to its exact Dashboard destination.
/// A delivered managed-agent snapshot wins; older dispatches fall back to the
/// linked board task without opening a legacy Session window.
@MainActor
enum TaskBoardSpawnedSessionNavigator {
  static func open(
    store _: HarnessMonitorStore,
    openWindow: OpenWindowAction,
    sessionID: String,
    workItemID: String?,
    managedAgent: ManagedAgentSnapshot? = nil
  ) {
    if let managedAgent {
      openWindow.openHarnessDashboardAgent(
        .managedAgent(
          sessionID: sessionID,
          runtimeKind: runtimeKind(for: managedAgent),
          managedAgentID: managedAgent.managedAgentID
        )
      )
    } else if let workItemID, !workItemID.isEmpty {
      openWindow.openHarnessDashboardTaskBoard(
        .loadedSessionTask(sessionID: sessionID, taskID: workItemID)
      )
    } else {
      openWindow.openHarnessDashboardAgent(.session(sessionID: sessionID))
    }
  }

  private static func runtimeKind(for snapshot: ManagedAgentSnapshot) -> DashboardAgentRuntimeKind {
    switch snapshot {
    case .terminal:
      .terminal
    case .codex:
      .codex
    case .acp:
      .acp
    }
  }
}
