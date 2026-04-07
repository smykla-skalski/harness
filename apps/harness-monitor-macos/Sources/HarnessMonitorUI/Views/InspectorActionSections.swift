import HarnessMonitorKit
import SwiftUI

struct InspectorActionSections: View {
  @Bindable var store: HarnessMonitorStore
  let detail: SessionDetail
  let selectedTask: WorkItem?
  let selectedAgent: AgentRegistration?
  let selectedObserver: ObserverSummary?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      InspectorActionStatusBanner(
        isSessionReadOnly: store.isSessionReadOnly,
        isSessionActionInFlight: store.isSessionActionInFlight,
        lastAction: store.lastAction,
        lastError: store.lastError,
        availableActionActors: store.availableActionActors,
        actionActorID: $store.selectedActionActorID
      )
      InspectorCreateTaskConsole(store: store)

      if let selectedTask {
        InspectorTaskMutationConsole(
          store: store,
          selectedTask: selectedTask,
          tasks: detail.tasks,
          agents: detail.agents
        )
      }

      if let selectedAgent {
        InspectorRoleMutationConsole(
          store: store,
          selectedAgent: selectedAgent,
          leaderID: detail.session.leaderId
        )
      }

      InspectorLeaderTransferConsole(
        store: store,
        detail: detail,
        actionActorID: store.selectedActionActorID
      )

      if let selectedObserver {
        InspectorObserverSummarySection(observer: selectedObserver)
      }
    }
  }
}
