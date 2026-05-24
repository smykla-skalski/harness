import HarnessMonitorKit
import SwiftUI

@MainActor
enum SessionItemContextMenuActionSupport {
  static func linkTask(
    state: SessionWindowStateCache,
    taskID: String,
    to decisionID: String
  ) {
    state.lastTaskDecisionLink = SessionTaskDecisionLink(
      sessionID: state.sessionID,
      taskID: taskID,
      decisionID: decisionID
    )
  }

  static func requestRemoveAgents(
    store: HarnessMonitorStore,
    sessionID: String,
    leaderID: String?,
    agents: [AgentRegistration],
    agentIDs: [String]
  ) {
    guard !agentIDs.isEmpty else { return }
    store.requestRemoveAgentConfirmation(
      sessionID: sessionID,
      agentIDs: agentIDs,
      leaderID: leaderID,
      agents: agents
    )
  }

  static func requestDeleteTasks(
    store: HarnessMonitorStore,
    state: SessionWindowStateCache,
    tasks: [WorkItem],
    taskIDs: [String]
  ) {
    guard !taskIDs.isEmpty else { return }
    let titlesByID = Dictionary(
      uniqueKeysWithValues: tasks.map { ($0.taskId, $0.title) }
    )
    store.requestDeleteTaskConfirmation(
      sessionID: state.sessionID,
      taskIDs: taskIDs
    ) { taskID in
      titlesByID[taskID] ?? taskID
    }
  }
}

struct SessionAgentContextMenuActions: View {
  let store: HarnessMonitorStore
  let state: SessionWindowStateCache
  let leaderID: String?
  let sessionAgents: [AgentRegistration]
  let resolution: SessionSidebarContextMenuResolution
  @Environment(\.undoManager)
  private var undoManager

  var body: some View {
    switch resolution {
    case .actionable(let scope):
      if !scope.isMulti {
        Menu("Move to...") {
          Button("Top") {
            state.sidebarOrdering.moveAgent(
              scope.primaryID,
              before: state.sidebarOrdering.agentIDs.first,
              undoManager: undoManager
            )
          }
          Button("Bottom") {
            state.sidebarOrdering.moveAgent(
              scope.primaryID,
              before: nil,
              undoManager: undoManager
            )
          }
        }
        Button("Move to Top") {
          state.sidebarOrdering.moveAgent(
            scope.primaryID,
            before: state.sidebarOrdering.agentIDs.first,
            undoManager: undoManager
          )
        }
        Button("Move to Bottom") {
          state.sidebarOrdering.moveAgent(
            scope.primaryID,
            before: nil,
            undoManager: undoManager
          )
        }
        Divider()
      }
      Button(scope.copyIDsLabel) {
        HarnessMonitorClipboard.copy(scope.clipboardText)
      }
      Divider()
      Button(scope.destructiveLabel, role: .destructive) {
        SessionItemContextMenuActionSupport.requestRemoveAgents(
          store: store,
          sessionID: state.sessionID,
          leaderID: leaderID,
          agents: sessionAgents,
          agentIDs: scope.ids
        )
      }
    case .unavailable(let message):
      Button(message) {}
        .disabled(true)
    }
  }
}

struct SessionTaskContextMenuActions: View {
  let store: HarnessMonitorStore
  let state: SessionWindowStateCache
  let tasks: [WorkItem]
  let decisions: [Decision]
  let resolution: SessionSidebarContextMenuResolution

  var body: some View {
    switch resolution {
    case .actionable(let scope):
      if !scope.isMulti {
        Menu("Move to...") {
          ForEach(decisions.prefix(10)) { decision in
            Button(decision.summary) {
              SessionItemContextMenuActionSupport.linkTask(
                state: state,
                taskID: scope.primaryID,
                to: decision.id
              )
            }
          }
          if decisions.isEmpty {
            Text("No visible decisions")
          }
          if decisions.count > 10 {
            Text("Filter decisions to show more")
          }
        }
      }
      Button(scope.copyIDsLabel) {
        HarnessMonitorClipboard.copy(scope.clipboardText)
      }
      Divider()
      Button(scope.destructiveLabel, role: .destructive) {
        SessionItemContextMenuActionSupport.requestDeleteTasks(
          store: store,
          state: state,
          tasks: tasks,
          taskIDs: scope.ids
        )
      }
    case .unavailable(let message):
      Button(message) {}
        .disabled(true)
    }
  }
}

struct SessionDecisionContextMenuActions: View {
  let resolution: SessionSidebarContextMenuResolution

  var body: some View {
    switch resolution {
    case .actionable(let scope):
      Button(scope.copyIDsLabel) {
        HarnessMonitorClipboard.copy(scope.clipboardText)
      }
    case .unavailable(let message):
      Button(message) {}
        .disabled(true)
    }
  }
}
