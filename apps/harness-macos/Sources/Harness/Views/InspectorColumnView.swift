import HarnessKit
import Observation
import SwiftUI

struct InspectorColumnView: View {
  let store: HarnessStore

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
    HarnessColumnScrollView(horizontalPadding: 18, verticalPadding: 22) {
      VStack(alignment: .leading, spacing: 18) {
        inspectorContent

        if let detail = store.selectedSession {
          InspectorActionSections(
            store: store,
            detail: detail,
            selectedTask: store.selectedTask,
            selectedAgent: store.selectedAgent,
            selectedObserver: selectedObserver
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
    VStack(alignment: .leading, spacing: 14) {
      Text("Inspector")
        .font(.system(.title3, design: .rounded, weight: .semibold))
      Text(summary.context)
        .font(.system(.headline, design: .rounded, weight: .semibold))
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
    VStack(alignment: .leading, spacing: 12) {
      Text("Inspector")
        .font(.system(.title3, design: .rounded, weight: .semibold))
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
    TaskInspectorCard(task: task, store: store)
  }

  private func agentInspector(_ agent: AgentRegistration) -> some View {
    AgentInspectorCard(
      agent: agent,
      activity: selectedAgentActivity,
      store: store
    )
  }

  private func signalInspector(_ signal: SessionSignalRecord) -> some View {
    SignalInspectorCard(signal: signal)
  }

  private func observerInspector(_ observer: ObserverSummary) -> some View {
    ObserverInspectorCard(observer: observer)
  }

}
