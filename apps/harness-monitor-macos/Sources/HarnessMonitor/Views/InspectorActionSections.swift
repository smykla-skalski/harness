import HarnessMonitorKit
import SwiftUI

struct InspectorActionSections: View {
  let detail: SessionDetail
  let selectedTask: WorkItem?
  let selectedAgent: AgentRegistration?
  let selectedObserver: ObserverSummary?
  let isSessionReadOnly: Bool
  let isSessionActionInFlight: Bool
  let lastAction: String
  let lastError: String?
  let availableActionActors: [AgentRegistration]
  @Binding var actionActorID: String
  let requestRemoveAgentConfirmation: (String) -> Void
  let createTaskAction: (String, String?, TaskSeverity) async -> Bool
  let assignTaskAction: (String, String) async -> Bool
  let updateTaskStatusAction: (String, TaskStatus, String?) async -> Bool
  let checkpointTaskAction: (String, String, Int) async -> Bool
  let changeRoleAction: (String, SessionRole) async -> Bool
  let transferLeaderAction: (String, String?) async -> Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      InspectorActionStatusBanner(
        isSessionReadOnly: isSessionReadOnly,
        isSessionActionInFlight: isSessionActionInFlight,
        lastAction: lastAction,
        lastError: lastError,
        availableActionActors: availableActionActors,
        actionActorID: $actionActorID
      )
      InspectorCreateTaskConsole(
        isSessionReadOnly: isSessionReadOnly,
        isSessionActionInFlight: isSessionActionInFlight,
        createTaskAction: createTaskAction
      )

      if let selectedTask {
        InspectorTaskMutationConsole(
          selectedTask: selectedTask,
          tasks: detail.tasks,
          agents: detail.agents,
          isSessionReadOnly: isSessionReadOnly,
          isSessionActionInFlight: isSessionActionInFlight,
          assignTaskAction: assignTaskAction,
          updateTaskStatusAction: updateTaskStatusAction,
          checkpointTaskAction: checkpointTaskAction
        )
      }

      if let selectedAgent {
        InspectorRoleMutationConsole(
          selectedAgent: selectedAgent,
          leaderID: detail.session.leaderId,
          isSessionReadOnly: isSessionReadOnly,
          isSessionActionInFlight: isSessionActionInFlight,
          changeRoleAction: changeRoleAction,
          requestRemoveAgentConfirmation: requestRemoveAgentConfirmation
        )
      }

      InspectorLeaderTransferConsole(
        detail: detail,
        actionActorID: actionActorID,
        isSessionReadOnly: isSessionReadOnly,
        isSessionActionInFlight: isSessionActionInFlight,
        transferLeaderAction: transferLeaderAction
      )

      if let selectedObserver {
        InspectorObserverSummarySection(observer: selectedObserver)
      }
    }
    .textFieldStyle(.roundedBorder)
  }
}
