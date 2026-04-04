import HarnessMonitorKit
import Observation
import SwiftData
import SwiftUI

private enum InspectorChromeMetrics {
  static let horizontalPadding: CGFloat = 16
  static let verticalPadding: CGFloat = 20
  static let contentSpacing: CGFloat = 16
}

struct InspectorColumnView: View {
  @Bindable var store: HarnessMonitorStore

  private var resolvedPrimaryContent: InspectorPrimaryContent {
    InspectorPrimaryContent(
      selectedSession: store.selectedSession,
      selectedSessionSummary: store.selectedSessionSummary,
      inspectorSelection: store.inspectorSelection,
      isPersistenceAvailable: store.isPersistenceAvailable
    )
  }

  private var selectedObserver: ObserverSummary? {
    resolvedPrimaryContent.observer
  }

  var body: some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: InspectorChromeMetrics.horizontalPadding,
      verticalPadding: InspectorChromeMetrics.verticalPadding,
      topScrollEdgeEffect: .hard
    ) {
      VStack(alignment: .leading, spacing: InspectorChromeMetrics.contentSpacing) {
        InspectorPrimaryContentHost(
          content: resolvedPrimaryContent,
          isSessionReadOnly: store.isSessionReadOnly,
          isSessionActionInFlight: store.isSessionActionInFlight,
          addNote: addTaskNote,
          deleteNote: deleteNote,
          sendSignal: sendSignal
        )
        .animation(.spring(duration: 0.2), value: resolvedPrimaryContent.identity)

        if let detail = store.selectedSession {
          InspectorActionSections(
            detail: detail,
            selectedTask: store.selectedTask,
            selectedAgent: store.selectedAgent,
            selectedObserver: selectedObserver,
            isSessionReadOnly: store.isSessionReadOnly,
            isSessionActionInFlight: store.isSessionActionInFlight,
            lastAction: store.lastAction,
            lastError: store.lastError,
            availableActionActors: store.availableActionActors,
            actionActorID: $store.selectedActionActorID,
            requestRemoveAgentConfirmation: store.requestRemoveAgentConfirmation(agentID:),
            createTaskAction: { title, context, severity in
              await store.createTask(title: title, context: context, severity: severity)
            },
            assignTaskAction: { taskID, agentID in
              await store.assignTask(taskID: taskID, agentID: agentID)
            },
            updateTaskStatusAction: { taskID, status, note in
              await store.updateTaskStatus(taskID: taskID, status: status, note: note)
            },
            checkpointTaskAction: { taskID, summary, progress in
              await store.checkpointTask(taskID: taskID, summary: summary, progress: progress)
            },
            changeRoleAction: { agentID, role in
              await store.changeRole(agentID: agentID, role: role)
            },
            transferLeaderAction: { newLeaderID, reason in
              await store.transferLeader(newLeaderID: newLeaderID, reason: reason)
            }
          )
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .foregroundStyle(HarnessMonitorTheme.ink)
    .textFieldStyle(.roundedBorder)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.inspectorRoot)
  }

  private func addTaskNote(_ text: String, targetID: String, sessionID: String) -> Bool {
    store.addNote(
      text: text,
      targetKind: "task",
      targetId: targetID,
      sessionId: sessionID
    )
  }

  private func deleteNote(_ note: UserNote) {
    _ = store.deleteNote(note)
  }

  private func sendSignal(
    agentID: String,
    command: String,
    message: String,
    actionHint: String?
  ) async {
    await store.sendSignal(
      agentID: agentID,
      command: command,
      message: message,
      actionHint: actionHint
    )
  }
}

private struct InspectorPrimaryContentHost: View {
  let content: InspectorPrimaryContent
  let isSessionReadOnly: Bool
  let isSessionActionInFlight: Bool
  let addNote: @MainActor (String, String, String) -> Bool
  let deleteNote: @MainActor (UserNote) -> Void
  let sendSignal: @MainActor (String, String, String, String?) async -> Void

  var body: some View {
    ZStack(alignment: .topLeading) {
      InspectorPrimaryLayer(isActive: content.isEmpty) {
        if content.isEmpty {
          InspectorPrimaryEmptyState()
        }
      }
      InspectorPrimaryLayer(isActive: content.loadingSummary != nil) {
        if let loadingSummary = content.loadingSummary {
          InspectorPrimaryLoadingState(summary: loadingSummary)
        }
      }
      InspectorPrimaryLayer(isActive: content.sessionDetail != nil) {
        if let sessionDetail = content.sessionDetail {
          SessionInspectorSummaryCard(detail: sessionDetail)
        }
      }
      InspectorPrimaryLayer(isActive: content.taskSelection != nil) {
        if let taskSelection = content.taskSelection {
          TaskInspectorCard(
            task: taskSelection.task,
            notesSessionID: taskSelection.notesSessionID,
            isPersistenceAvailable: taskSelection.isPersistenceAvailable,
            addNote: addNote,
            deleteNote: deleteNote
          )
        }
      }
      InspectorPrimaryLayer(isActive: content.agentSelection != nil) {
        if let agentSelection = content.agentSelection {
          AgentInspectorCard(
            agent: agentSelection.agent,
            activity: agentSelection.activity,
            isSessionReadOnly: isSessionReadOnly,
            isSessionActionInFlight: isSessionActionInFlight
          ) { command, message, actionHint in
            await sendSignal(agentSelection.agent.agentId, command, message, actionHint)
          }
        }
      }
      InspectorPrimaryLayer(isActive: content.signal != nil) {
        if let signal = content.signal {
          SignalInspectorCard(signal: signal)
        }
      }
      InspectorPrimaryLayer(isActive: content.observer != nil) {
        if let observer = content.observer {
          ObserverInspectorCard(observer: observer)
        }
      }
    }
  }
}

private struct InspectorPrimaryLayer<Content: View>: View {
  let isActive: Bool
  @ViewBuilder let content: Content

  var body: some View {
    content
      .opacity(isActive ? 1 : 0)
      .allowsHitTesting(isActive)
      .accessibilityHidden(!isActive)
  }
}

private struct InspectorPrimaryEmptyState: View {
  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Inspector")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Text("Select a session to inspect live task, agent, and signal detail.")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.inspectorEmptyState,
      label: "Inspector",
      value: "empty"
    )
  }
}

private struct InspectorPrimaryLoadingState: View {
  let summary: SessionSummary

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Inspector")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Text(summary.context)
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
      Text("Loading live task, agent, and signal detail for the selected session.")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      HarnessMonitorLoadingStateView(title: "Loading session detail")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.sessionInspectorCard,
      label: "Inspector",
      value: "loading"
    )
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.sessionInspectorCard).frame")
  }
}

private struct InspectorTaskSelection {
  let task: WorkItem
  let notesSessionID: String?
  let isPersistenceAvailable: Bool
}

private struct InspectorAgentSelection {
  let agent: AgentRegistration
  let activity: AgentToolActivitySummary?
}

private enum InspectorPrimaryContent {
  case empty
  case loading(SessionSummary)
  case session(SessionDetail)
  case task(InspectorTaskSelection)
  case agent(InspectorAgentSelection)
  case signal(SessionSignalRecord)
  case observer(ObserverSummary)

  var identity: String {
    switch self {
    case .empty:
      return "empty"
    case .loading(let summary):
      return "loading:\(summary.sessionId)"
    case .session(let detail):
      return "session:\(detail.session.sessionId)"
    case .task(let selection):
      return "task:\(selection.task.taskId)"
    case .agent(let selection):
      return "agent:\(selection.agent.agentId)"
    case .signal(let signal):
      return "signal:\(signal.signal.signalId)"
    case .observer(let observer):
      return "observer:\(observer.observeId)"
    }
  }

  var isEmpty: Bool {
    if case .empty = self {
      return true
    }
    return false
  }

  var loadingSummary: SessionSummary? {
    guard case .loading(let summary) = self else {
      return nil
    }
    return summary
  }

  var sessionDetail: SessionDetail? {
    guard case .session(let detail) = self else {
      return nil
    }
    return detail
  }

  var taskSelection: InspectorTaskSelection? {
    guard case .task(let selection) = self else {
      return nil
    }
    return selection
  }

  var agentSelection: InspectorAgentSelection? {
    guard case .agent(let selection) = self else {
      return nil
    }
    return selection
  }

  var signal: SessionSignalRecord? {
    guard case .signal(let signal) = self else {
      return nil
    }
    return signal
  }

  var observer: ObserverSummary? {
    guard case .observer(let observer) = self else {
      return nil
    }
    return observer
  }

  init(
    selectedSession: SessionDetail?,
    selectedSessionSummary: SessionSummary?,
    inspectorSelection: HarnessMonitorStore.InspectorSelection,
    isPersistenceAvailable: Bool
  ) {
    guard let selectedSession else {
      if let selectedSessionSummary {
        self = .loading(selectedSessionSummary)
      } else {
        self = .empty
      }
      return
    }

    self = Self.resolveSelection(
      selectedSession: selectedSession,
      inspectorSelection: inspectorSelection,
      isPersistenceAvailable: isPersistenceAvailable
    )
  }

  private static func resolveSelection(
    selectedSession: SessionDetail,
    inspectorSelection: HarnessMonitorStore.InspectorSelection,
    isPersistenceAvailable: Bool
  ) -> Self {
    switch inspectorSelection {
    case .none:
      return .session(selectedSession)
    case .task(let taskID):
      guard let task = selectedSession.tasks.first(where: { $0.taskId == taskID }) else {
        return .session(selectedSession)
      }
      return .task(
        InspectorTaskSelection(
          task: task,
          notesSessionID: selectedSession.session.sessionId,
          isPersistenceAvailable: isPersistenceAvailable
        )
      )
    case .agent(let agentID):
      guard let agent = selectedSession.agents.first(where: { $0.agentId == agentID }) else {
        return .session(selectedSession)
      }
      return .agent(
        InspectorAgentSelection(
          agent: agent,
          activity: selectedSession.agentActivity.first(where: { $0.agentId == agent.agentId })
        )
      )
    case .signal(let signalID):
      guard let signal = selectedSession.signals.first(where: { $0.signal.signalId == signalID }) else {
        return .session(selectedSession)
      }
      return .signal(signal)
    case .observer:
      if let observer = selectedSession.observer {
        return .observer(observer)
      }
      return .session(selectedSession)
    }
  }
}

#Preview("Inspector - Session") {
  let store = inspectorPreviewStore(selection: .none)

  InspectorColumnView(store: store)
    .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
    .frame(width: 420, height: 860)
}

#Preview("Inspector - Task") {
  let store = inspectorPreviewStore(selection: .task(PreviewFixtures.tasks[0].taskId))

  InspectorColumnView(store: store)
    .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
    .frame(width: 420, height: 860)
}

#Preview("Inspector - Agent") {
  let store = inspectorPreviewStore(selection: .agent(PreviewFixtures.agents[0].agentId))

  InspectorColumnView(store: store)
    .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
    .frame(width: 420, height: 860)
}

#Preview("Inspector - Observer") {
  let store = inspectorPreviewStore(selection: .observer)

  InspectorColumnView(store: store)
    .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
    .frame(width: 420, height: 860)
}

#Preview("Inspector - Empty") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(
    for: .dashboardLoaded,
    modelContainer: HarnessMonitorPreviewStoreFactory.previewContainer
  )

  InspectorColumnView(store: store)
    .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
    .frame(width: 420, height: 860)
}

@MainActor
private func inspectorPreviewStore(
  selection: HarnessMonitorStore.InspectorSelection
) -> HarnessMonitorStore {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(
    for: .cockpitLoaded,
    modelContainer: HarnessMonitorPreviewStoreFactory.previewContainer
  )
  store.inspectorSelection = selection
  return store
}
