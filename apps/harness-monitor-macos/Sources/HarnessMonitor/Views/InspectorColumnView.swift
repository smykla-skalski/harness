import HarnessMonitorKit
import Observation
import SwiftUI

struct InspectorColumnView: View {
  @Bindable var store: MonitorStore
  @State private var signalCommand = "inject_context"
  @State private var signalMessage = ""
  @State private var signalActionHint = ""

  private var selectedObserver: ObserverSummary? {
    guard case .observer = store.inspectorSelection else {
      return nil
    }
    return store.selectedSession?.observer
  }

  private var selectedSessionSummary: SessionSummary? {
    store.selectedSessionSummary
  }

  private var selectedAgentActivity: AgentToolActivitySummary? {
    guard let agent = store.selectedAgent else {
      return nil
    }
    return store.selectedSession?.agentActivity.first(where: { $0.agentId == agent.agentId })
  }

  private var selectionKey: String {
    [
      store.selectedSession?.session.sessionId ?? "-",
      store.selectedTask?.taskId ?? "-",
      store.selectedAgent?.agentId ?? "-",
      store.selectedSignal?.signal.signalId ?? "-",
      selectedObserver?.observeId ?? "-",
    ].joined(separator: "|")
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      MonitorTheme.inspectorBackground

      MonitorColumnScrollView(horizontalPadding: 18, verticalPadding: 22) {
        VStack(alignment: .leading, spacing: 18) {
          if let task = store.selectedTask {
            taskInspector(task)
          } else if let agent = store.selectedAgent {
            agentInspector(agent)
          } else if let signal = store.selectedSignal {
            signalInspector(signal)
          } else if let observer = selectedObserver {
            observerInspector(observer)
          } else if let detail = store.selectedSession {
            sessionInspector(detail)
          } else if let summary = selectedSessionSummary {
            sessionLoadingInspector(summary)
          } else {
            emptyState
          }

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
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .foregroundStyle(MonitorTheme.ink)
    .textFieldStyle(.roundedBorder)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(MonitorAccessibility.inspectorRoot)
    .task(id: selectionKey) {
      syncSignalDraft()
    }
  }

  private func sessionLoadingInspector(_ summary: SessionSummary) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Inspector")
        .font(.system(.title3, design: .serif, weight: .semibold))
      Text(summary.context)
        .font(.system(.headline, design: .rounded, weight: .semibold))
      Text("Loading live task, agent, and signal detail for the selected session.")
        .foregroundStyle(.secondary)
      MonitorLoadingStateView(title: "Loading session detail")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .monitorCard()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(MonitorAccessibility.sessionInspectorCard)
    .accessibilityFrameMarker(MonitorAccessibility.sessionInspectorCard)
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Inspector")
        .font(.system(.title3, design: .serif, weight: .semibold))
      Text("Select a session to inspect live task, agent, and signal detail.")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .monitorCard()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(MonitorAccessibility.inspectorEmptyState)
  }

  @ViewBuilder
  private func sessionInspector(_ detail: SessionDetail) -> some View {
    SessionInspectorSummaryCard(detail: detail)
  }

  @ViewBuilder
  private func taskInspector(_ task: WorkItem) -> some View {
    TaskInspectorCard(task: task)
  }

  @ViewBuilder
  private func agentInspector(_ agent: AgentRegistration) -> some View {
    AgentInspectorCard(
      agent: agent,
      activity: selectedAgentActivity,
      signalCommand: $signalCommand,
      signalMessage: $signalMessage,
      signalActionHint: $signalActionHint,
      sendSignal: sendSignalToSelectedAgent
    )
  }

  @ViewBuilder
  private func signalInspector(_ signal: SessionSignalRecord) -> some View {
    SignalInspectorCard(signal: signal)
  }

  @ViewBuilder
  private func observerInspector(_ observer: ObserverSummary) -> some View {
    ObserverInspectorCard(observer: observer)
  }

  private func sendSignalToSelectedAgent() {
    guard let agent = store.selectedAgent else {
      return
    }
    Task {
      await store.sendSignal(
        agentID: agent.agentId,
        command: signalCommand,
        message: signalMessage,
        actionHint: signalActionHint.isEmpty ? nil : signalActionHint
      )
    }
  }

  private func syncSignalDraft() {
    if let signal = store.selectedSignal {
      signalCommand = signal.signal.command
      signalMessage = signal.signal.payload.message
      signalActionHint = signal.signal.payload.actionHint ?? ""
      return
    }

    if store.selectedAgent != nil {
      signalCommand = "inject_context"
      signalMessage = ""
      signalActionHint = ""
    }
  }
}
