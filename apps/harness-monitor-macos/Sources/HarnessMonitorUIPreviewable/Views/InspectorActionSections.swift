import HarnessMonitorKit
import SwiftUI

public struct InspectorActionSections: View {
  public let store: HarnessMonitorStore
  public let context: HarnessMonitorStore.InspectorActionContext

  public init(store: HarnessMonitorStore, context: HarnessMonitorStore.InspectorActionContext) {
    self.store = store
    self.context = context
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      InspectorActionStatusBanner(
        unavailableMessage: store.selectedSessionActionBannerMessage,
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
