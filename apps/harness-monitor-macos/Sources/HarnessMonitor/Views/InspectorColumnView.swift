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

  var body: some View {
    ScrollView {
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
      .padding(22)
    }
    .background(MonitorTheme.canvas.ignoresSafeArea())
    .foregroundStyle(MonitorTheme.ink)
  }

  private func sessionInspector(_ detail: SessionDetail) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Inspector")
        .font(.system(.title3, design: .serif, weight: .semibold))
      Text(
        "Pick a task, agent, signal, or observe card from the cockpit to focus actions and detail here."
      )
      .foregroundStyle(.secondary)
      HStack {
        keyValue("Leader", detail.session.leaderId ?? "n/a")
        keyValue("Last Activity", formatTimestamp(detail.session.lastActivityAt))
      }
    }
    .monitorCard()
  }

  private func taskInspector(_ task: WorkItem) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(task.title)
        .font(.system(.title3, design: .serif, weight: .bold))
      Text(task.context ?? "No task context provided.")
        .foregroundStyle(.secondary)
      keyValue("Severity", task.severity.rawValue.capitalized)
      keyValue("Status", task.status.rawValue.capitalized)
      keyValue("Assignee", task.assignedTo ?? "Unassigned")
      if let checkpoint = task.checkpointSummary {
        keyValue("Checkpoint", "\(checkpoint.progress)% • \(checkpoint.summary)")
      }
      if let suggestion = task.suggestedFix {
        Text("Suggested Fix")
          .font(.headline)
        Text(suggestion)
          .foregroundStyle(.secondary)
      }
    }
    .monitorCard()
  }

  private func agentInspector(_ agent: AgentRegistration) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(agent.name)
        .font(.system(.title3, design: .serif, weight: .bold))
      Text("\(agent.runtime) • \(agent.role.rawValue.capitalized)")
        .foregroundStyle(.secondary)
      keyValue("Current Task", agent.currentTaskId ?? "Idle")
      keyValue("Last Activity", formatTimestamp(agent.lastActivityAt))
      keyValue(
        "Signal Pickup",
        "\(agent.runtimeCapabilities.typicalSignalLatencySeconds)s typical"
      )
      Text("Send Signal")
        .font(.headline)
      TextField("Command", text: $signalCommand)
      TextField("Message", text: $signalMessage, axis: .vertical)
        .lineLimit(3, reservesSpace: true)
      TextField("Action Hint", text: $signalActionHint)
      Button("Send") {
        Task {
          await store.sendSignal(
            agentID: agent.agentId,
            command: signalCommand,
            message: signalMessage,
            actionHint: signalActionHint.isEmpty ? nil : signalActionHint
          )
        }
      }
      .buttonStyle(.borderedProminent)
      .tint(MonitorTheme.accent)
      .disabled(signalCommand.isEmpty || signalMessage.isEmpty)
    }
    .textFieldStyle(.roundedBorder)
    .monitorCard()
  }

  private func signalInspector(_ signal: SessionSignalRecord) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(signal.signal.command)
        .font(.system(.title3, design: .serif, weight: .bold))
      Text(signal.signal.payload.message)
        .foregroundStyle(.secondary)
      keyValue("Status", signal.status.rawValue.capitalized)
      keyValue("Agent", signal.agentId)
      keyValue("Priority", signal.signal.priority.rawValue.capitalized)
      keyValue("Created", formatTimestamp(signal.signal.createdAt))
      if let acknowledgment = signal.acknowledgment {
        keyValue("Acknowledged", acknowledgment.result.rawValue.capitalized)
        if let details = acknowledgment.details {
          Text(details)
            .foregroundStyle(.secondary)
        }
      }
    }
    .monitorCard()
  }

  private func observerInspector(_ observer: ObserverSummary) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Observe")
        .font(.system(.title3, design: .serif, weight: .bold))
      keyValue("Observer", observer.observeId)
      keyValue("Open Issues", "\(observer.openIssueCount)")
      keyValue("Muted Codes", "\(observer.mutedCodeCount)")
      keyValue("Active Workers", "\(observer.activeWorkerCount)")
      keyValue("Last Sweep", formatTimestamp(observer.lastScanTime))
    }
    .monitorCard()
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Inspector")
        .font(.system(.title3, design: .serif, weight: .semibold))
      Text("Select a session to inspect live task, agent, and signal detail.")
        .foregroundStyle(.secondary)
    }
    .monitorCard()
  }

  private func keyValue(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.body, design: .rounded, weight: .semibold))
    }
  }
}
