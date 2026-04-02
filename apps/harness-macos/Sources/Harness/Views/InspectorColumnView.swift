import HarnessKit
import Observation
import SwiftUI

struct InspectorColumnView: View {
  @Bindable var store: HarnessStore

  private var selectedObserver: ObserverSummary? {
    guard case .observer = store.inspectorSelection else { return nil }
    return store.selectedSession?.observer
  }

  private var selectedAgentActivity: AgentToolActivitySummary? {
    guard let agent = store.selectedAgent else {
      return nil
    }
    return store.selectedSession?.agentActivity.first(where: { $0.agentId == agent.agentId })
  }

  var body: some View {
    HarnessColumnScrollView(horizontalPadding: 16, verticalPadding: 20) {
      VStack(alignment: .leading, spacing: 16) {
        Group {
          inspectorContent
        }
        .animation(.spring(duration: 0.2), value: store.inspectorSelection)

        if let detail = store.selectedSession {
          InspectorActionSections(
            detail: detail,
            selectedTask: store.selectedTask,
            selectedAgent: store.selectedAgent,
            selectedObserver: selectedObserver,
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
    .foregroundStyle(HarnessTheme.ink)
    .textFieldStyle(.roundedBorder)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.inspectorRoot)
  }

  @ViewBuilder private var inspectorContent: some View {
    if let detail = store.selectedSession {
      switch store.inspectorSelection {
      case .none:
        sessionInspector(detail)
      case .task(let taskID):
        if let task = detail.tasks.first(where: { $0.taskId == taskID }) {
          taskInspector(task)
        } else {
          sessionInspector(detail)
        }
      case .agent(let agentID):
        if let agent = detail.agents.first(where: { $0.agentId == agentID }) {
          agentInspector(agent)
        } else {
          sessionInspector(detail)
        }
      case .signal(let signalID):
        if let signal = detail.signals.first(where: { $0.signal.signalId == signalID }) {
          signalInspector(signal)
        } else {
          sessionInspector(detail)
        }
      case .observer:
        if let observer = detail.observer {
          observerInspector(observer)
        } else {
          sessionInspector(detail)
        }
      }
    } else if let summary = store.selectedSessionSummary {
      sessionLoadingInspector(summary)
    } else {
      emptyState
    }
  }

  private func sessionLoadingInspector(_ summary: SessionSummary) -> some View {
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      Text("Inspector")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Text(summary.context)
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
      Text("Loading live task, agent, and signal detail for the selected session.")
        .foregroundStyle(HarnessTheme.secondaryInk)
      HarnessLoadingStateView(title: "Loading session detail")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessAccessibility.sessionInspectorCard,
      label: "Inspector",
      value: "loading"
    )
    .accessibilityFrameMarker("\(HarnessAccessibility.sessionInspectorCard).frame")
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      Text("Inspector")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Text("Select a session to inspect live task, agent, and signal detail.")
        .foregroundStyle(HarnessTheme.secondaryInk)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessAccessibility.inspectorEmptyState,
      label: "Inspector",
      value: "empty"
    )
  }

  private func sessionInspector(_ detail: SessionDetail) -> some View {
    SessionInspectorSummaryCard(detail: detail)
  }

  private func taskInspector(_ task: WorkItem) -> some View {
    TaskInspectorCard(
      task: task,
      notesSessionID: store.selectedSession?.session.sessionId,
      isPersistenceAvailable: store.isPersistenceAvailable,
      addNote: { text, targetID, sessionID in
        store.addNote(
          text: text,
          targetKind: "task",
          targetId: targetID,
          sessionId: sessionID
        )
      },
      deleteNote: { _ = store.deleteNote($0) }
    )
  }

  private func agentInspector(_ agent: AgentRegistration) -> some View {
    AgentInspectorCard(
      agent: agent,
      activity: selectedAgentActivity,
      isSessionActionInFlight: store.isSessionActionInFlight
    ) { command, message, actionHint in
      await store.sendSignal(
        agentID: agent.agentId,
        command: command,
        message: message,
        actionHint: actionHint
      )
    }
  }

  private func signalInspector(_ signal: SessionSignalRecord) -> some View {
    SignalInspectorCard(signal: signal)
  }

  private func observerInspector(_ observer: ObserverSummary) -> some View {
    ObserverInspectorCard(observer: observer)
  }
}
