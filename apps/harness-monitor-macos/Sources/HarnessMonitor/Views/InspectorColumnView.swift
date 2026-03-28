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
    .accessibilityFrameMarker(MonitorAccessibility.inspectorRoot)
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
    .frame(maxWidth: .infinity, alignment: .leading)
    .monitorCard()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(MonitorAccessibility.sessionInspectorCard)
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
      if let mutedCodes = observer.mutedCodes, !mutedCodes.isEmpty {
        detailSection(title: "Muted Codes") {
          flowBadges(mutedCodes.map { $0.replacingOccurrences(of: "_", with: " ") })
        }
      }
      if let openIssues = observer.openIssues, !openIssues.isEmpty {
        detailSection(title: "Open Issues") {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(openIssues) { issue in
              VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                  Text(issue.code)
                    .font(.caption.bold())
                    .textCase(.uppercase)
                  Spacer()
                  Text(issue.severity.capitalized)
                    .font(.caption2.bold())
                }
                Text(issue.summary)
                  .font(.subheadline)
                if let evidenceExcerpt = issue.evidenceExcerpt {
                  Text(evidenceExcerpt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            }
          }
        }
      }
      if let activeWorkers = observer.activeWorkers, !activeWorkers.isEmpty {
        detailSection(title: "Active Workers") {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(activeWorkers) { worker in
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Text(worker.agentId ?? "worker")
                    .font(.subheadline.bold())
                  Spacer()
                  Text(worker.startedAt)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                }
                Text(worker.targetFile)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .monitorCard()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(MonitorAccessibility.observerInspectorCard)
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

  private func keyValue(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.body, design: .rounded, weight: .semibold))
    }
  }

  private func detailSection<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption.bold())
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
      content()
    }
  }

  private func flowBadges(_ values: [String]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(values, id: \.self) { value in
        Text(value)
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(Color.white.opacity(0.68), in: Capsule())
      }
    }
  }
}

struct InspectorObserverSummarySection: View {
  let observer: ObserverSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      monitorActionHeader(
        title: "Observe",
        subtitle: "The observer loop keeps the session moving and surfaces drift."
      )
      HStack {
        monitorBadge("Open \(observer.openIssueCount)")
        monitorBadge("Muted \(observer.mutedCodeCount)")
        monitorBadge("Workers \(observer.activeWorkerCount)")
      }
      Text("Last sweep \(formatTimestamp(observer.lastScanTime))")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
      if let mutedCodes = observer.mutedCodes, !mutedCodes.isEmpty {
        Text("Muted codes")
          .font(.caption.bold())
          .foregroundStyle(.secondary)
        Text(mutedCodes.prefix(3).joined(separator: " · "))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let openIssues = observer.openIssues, !openIssues.isEmpty {
        Text("Open issues")
          .font(.caption.bold())
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 6) {
          ForEach(openIssues.prefix(2)) { issue in
            VStack(alignment: .leading, spacing: 2) {
              Text("\(issue.code) · \(issue.summary)")
                .font(.caption)
              Text("Severity \(issue.severity.capitalized)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      if let activeWorkers = observer.activeWorkers, !activeWorkers.isEmpty {
        Text("Active workers")
          .font(.caption.bold())
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 6) {
          ForEach(activeWorkers.prefix(2)) { worker in
            VStack(alignment: .leading, spacing: 2) {
              Text(worker.agentId ?? "worker")
                .font(.caption)
              Text(worker.targetFile)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
        }
      }
    }
    .monitorCard()
  }
}
