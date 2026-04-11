import HarnessMonitorKit
import SwiftUI

struct InspectorActionSections: View {
  let store: HarnessMonitorStore
  let context: HarnessMonitorStore.InspectorActionContext

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      InspectorActionStatusBanner(
        isSessionReadOnly: context.isSessionReadOnly,
        actionActorOptions: context.actionActorOptions,
        actionActorID: Binding(
          get: { context.selectedActionActorID },
          set: { store.selectedActionActorID = $0 }
        )
      )
      InspectorCreateTaskConsole(store: store)

      if let selectedTask = context.selectedTask {
        InspectorTaskMutationConsole(
          store: store,
          sessionID: context.detail.session.sessionId,
          selectedTask: selectedTask,
          tasks: context.detail.tasks,
          agents: context.detail.agents
        )
        .id("task:\(context.detail.session.sessionId):\(selectedTask.taskId)")
      }

      if let selectedAgent = context.selectedAgent {
        let roleConsoleIdentity = [
          "agent",
          context.detail.session.sessionId,
          selectedAgent.agentId,
          selectedAgent.role.rawValue,
          context.detail.session.leaderId ?? "-",
        ].joined(separator: ":")

        InspectorRoleMutationConsole(
          store: store,
          sessionID: context.detail.session.sessionId,
          selectedAgent: selectedAgent,
          leaderID: context.detail.session.leaderId
        )
        .id(roleConsoleIdentity)
      }

      InspectorLeaderTransferConsole(
        store: store,
        detail: context.detail,
        actionActorID: context.selectedActionActorID
      )
      .id("leader:\(context.detail.session.sessionId):\(context.detail.session.leaderId ?? "-")")

      if let selectedObserver = context.selectedObserver {
        InspectorObserverSummarySection(observer: selectedObserver)
      }
    }
  }
}
