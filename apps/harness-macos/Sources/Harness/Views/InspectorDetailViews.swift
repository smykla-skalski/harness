import HarnessKit
import SwiftUI

struct SessionInspectorSummaryCard: View {
  let detail: SessionDetail

  private var facts: [InspectorFact] {
    [
      .init(title: "Leader", value: detail.session.leaderId ?? "n/a"),
      .init(title: "Last Activity", value: formatTimestamp(detail.session.lastActivityAt)),
      .init(title: "Open Tasks", value: "\(detail.session.metrics.openTaskCount)"),
      .init(title: "Active Agents", value: "\(detail.session.metrics.activeAgentCount)"),
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Inspector")
        .font(.system(.title3, design: .rounded, weight: .semibold))
      Text(
        "Pick a task, agent, signal, or observe card from the cockpit to focus actions and detail here."
      )
      .foregroundStyle(HarnessTheme.secondaryInk)
      InspectorFactGrid(facts: facts)
      if !detail.agentActivity.isEmpty {
        InspectorSection(title: "Recent Agent Activity") {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(detail.agentActivity.prefix(2)) { activity in
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Text(activity.agentId)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                  Spacer()
                  Text(activity.latestEventAt.map(formatTimestamp) ?? "No events")
                    .font(.caption.monospaced())
                    .foregroundStyle(HarnessTheme.secondaryInk)
                }
                Text(activity.recentTools.joined(separator: " · "))
                  .font(.caption)
                  .foregroundStyle(HarnessTheme.secondaryInk)
                  .lineLimit(2)
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessAccessibility.sessionInspectorCard,
      label: "Inspector",
      value: detail.session.sessionId
    )
    .accessibilityFrameMarker("\(HarnessAccessibility.sessionInspectorCard).frame")
  }
}

struct TaskInspectorCard: View {
  let task: WorkItem
  let store: HarnessStore
  @State private var newNoteText = ""

  private var userNotes: [UserNote] {
    store.notes(for: task.taskId)
  }

  private var facts: [InspectorFact] {
    [
      .init(title: "Severity", value: task.severity.title),
      .init(title: "Status", value: task.status.title),
      .init(title: "Assignee", value: task.assignedTo ?? "Unassigned"),
      .init(title: "Source", value: task.source.title),
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(task.title)
        .font(.system(.title3, design: .rounded, weight: .bold))
      Text(task.context ?? "No task context provided.")
        .foregroundStyle(HarnessTheme.secondaryInk)
      InspectorFactGrid(facts: facts)
      if let checkpoint = task.checkpointSummary {
        InspectorSection(title: "Checkpoint") {
          InspectorFactGrid(
            facts: [
              .init(title: "Progress", value: "\(checkpoint.progress)%"),
              .init(title: "Recorded", value: formatTimestamp(checkpoint.recordedAt)),
            ]
          )
          Text(checkpoint.summary)
            .font(.subheadline)
            .foregroundStyle(HarnessTheme.secondaryInk)
        }
      }
      if let suggestion = task.suggestedFix {
        InspectorSection(title: "Suggested Fix") {
          Text(suggestion)
            .foregroundStyle(HarnessTheme.secondaryInk)
        }
      }
      if !task.notes.isEmpty {
        InspectorSection(title: "Notes") {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(task.notes) { note in
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Text(note.agentId ?? "system")
                    .font(.caption.bold())
                  Spacer()
                  Text(formatTimestamp(note.timestamp))
                    .font(.caption.monospaced())
                    .foregroundStyle(HarnessTheme.secondaryInk)
                }
                Text(note.text)
                  .font(.subheadline)
                  .foregroundStyle(HarnessTheme.secondaryInk)
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      if let blockedReason = task.blockedReason, !blockedReason.isEmpty {
        InspectorSection(title: "Blocked Reason") {
          Text(blockedReason)
            .font(.subheadline)
            .foregroundStyle(HarnessTheme.danger)
        }
      }
      if let completedAt = task.completedAt {
        InspectorSection(title: "Completed") {
          Text(formatTimestamp(completedAt))
            .font(.subheadline.monospaced())
            .foregroundStyle(HarnessTheme.secondaryInk)
        }
      }
      InspectorSection(title: "Your Notes") {
        if !userNotes.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(userNotes, id: \.persistentModelID) { note in
              HStack(alignment: .top) {
                Text(note.text)
                  .font(.subheadline)
                  .foregroundStyle(HarnessTheme.secondaryInk)
                  .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                  store.deleteNote(note)
                } label: {
                  Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(HarnessTheme.secondaryInk)
                }
                .buttonStyle(.borderless)
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack(spacing: 8) {
          TextField("Add a note", text: $newNoteText)
            .textFieldStyle(.roundedBorder)
            .onSubmit { submitNote() }
          Button("Add") { submitNote() }
            .disabled(newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessAccessibility.taskInspectorCard,
      label: task.title,
      value: task.taskId
    )
    .accessibilityFrameMarker("\(HarnessAccessibility.taskInspectorCard).frame")
  }

  private func submitNote() {
    let text = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    guard let sessionId = store.selectedSession?.session.sessionId else { return }
    store.addNote(text: text, targetKind: "task", targetId: task.taskId, sessionId: sessionId)
    newNoteText = ""
  }
}

struct AgentInspectorCard: View {
  let agent: AgentRegistration
  let activity: AgentToolActivitySummary?
  let store: HarnessStore
  @State private var signalCommand = "inject_context"
  @State private var signalMessage = ""
  @State private var signalActionHint = ""

  private var facts: [InspectorFact] {
    [
      .init(title: "Role", value: agent.role.title),
      .init(title: "Current Task", value: agent.currentTaskId ?? "Idle"),
      .init(title: "Last Activity", value: formatTimestamp(agent.lastActivityAt)),
      .init(
        title: "Signal Pickup",
        value: "\(agent.runtimeCapabilities.typicalSignalLatencySeconds)s typical"
      ),
    ]
  }

  private var capabilityBadges: [String] {
    agent.capabilities.isEmpty ? ["No declared capabilities"] : agent.capabilities
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(agent.name)
        .font(.system(.title3, design: .rounded, weight: .bold))
      Text("\(agent.runtime) • \(agent.role.title)")
        .foregroundStyle(HarnessTheme.secondaryInk)
      InspectorFactGrid(facts: facts)
      InspectorSection(title: "Runtime Capabilities") {
        InspectorFactGrid(
          facts: [
            .init(
              title: "Transcript",
              value: agent.runtimeCapabilities.supportsNativeTranscript ? "Native" : "Ledger"
            ),
            .init(
              title: "Signal Delivery",
              value: agent.runtimeCapabilities.supportsSignalDelivery ? "Supported" : "Unavailable"
            ),
            .init(
              title: "Context Injection",
              value: agent.runtimeCapabilities.supportsContextInjection
                ? "Supported" : "Unavailable"
            ),
          ]
        )
      }
      InspectorSection(title: "Declared Capabilities") {
        InspectorBadgeColumn(values: capabilityBadges)
      }
      if !agent.runtimeCapabilities.hookPoints.isEmpty {
        InspectorSection(title: "Hook Points") {
          InspectorBadgeColumn(
            values: agent.runtimeCapabilities.hookPoints.map { hook in
              let context = hook.supportsContextInjection ? "context" : "no-context"
              return "\(hook.name) · \(hook.typicalLatencySeconds)s · \(context)"
            }
          )
        }
      }
      if let activity {
        InspectorSection(title: "Tool Activity") {
          InspectorFactGrid(
            facts: [
              .init(title: "Invocations", value: "\(activity.toolInvocationCount)"),
              .init(title: "Results", value: "\(activity.toolResultCount)"),
              .init(title: "Errors", value: "\(activity.toolErrorCount)"),
              .init(title: "Latest Tool", value: activity.latestToolName ?? "Unknown"),
            ]
          )
          if !activity.recentTools.isEmpty {
            Text("Recent Tools")
              .font(.caption.bold())
              .foregroundStyle(HarnessTheme.secondaryInk)
            Text(activity.recentTools.joined(separator: " · "))
              .font(.caption)
              .foregroundStyle(HarnessTheme.secondaryInk)
          }
        }
      }
      InspectorSection(title: "Send Signal") {
        TextField("Command", text: $signalCommand)
        TextField("Message", text: $signalMessage, axis: .vertical)
          .lineLimit(3, reservesSpace: true)
        TextField("Action Hint", text: $signalActionHint)
        Button("Send Signal") {
          Task {
            await store.sendSignal(
              agentID: agent.agentId,
              command: signalCommand,
              message: signalMessage,
              actionHint: signalActionHint.isEmpty ? nil : signalActionHint
            )
          }
        }
        .harnessActionButtonStyle(variant: .prominent, tint: nil)
        .disabled(signalCommand.isEmpty || signalMessage.isEmpty)
        .accessibilityIdentifier(HarnessAccessibility.signalSendButton)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessAccessibility.agentInspectorCard,
      label: agent.name,
      value: agent.agentId
    )
    .accessibilityFrameMarker("\(HarnessAccessibility.agentInspectorCard).frame")
  }
}

struct SignalInspectorCard: View {
  let signal: SessionSignalRecord

  private var facts: [InspectorFact] {
    [
      .init(title: "Status", value: signal.status.title),
      .init(title: "Agent", value: signal.agentId),
      .init(title: "Runtime", value: signal.runtime),
      .init(title: "Priority", value: signal.signal.priority.title),
      .init(title: "Created", value: formatTimestamp(signal.signal.createdAt)),
      .init(title: "Expires", value: formatTimestamp(signal.signal.expiresAt)),
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(signal.signal.command)
        .font(.system(.title3, design: .rounded, weight: .bold))
      Text(signal.signal.payload.message)
        .foregroundStyle(.secondary)
      InspectorFactGrid(facts: facts)
      InspectorSection(title: "Delivery") {
        InspectorFactGrid(
          facts: [
            .init(title: "Retries", value: "\(signal.signal.delivery.retryCount)"),
            .init(title: "Max Retries", value: "\(signal.signal.delivery.maxRetries)"),
            .init(
              title: "Idempotency",
              value: signal.signal.delivery.idempotencyKey ?? "Not set"
            ),
          ]
        )
      }
      if let actionHint = signal.signal.payload.actionHint, !actionHint.isEmpty {
        InspectorSection(title: "Action Hint") {
          Text(actionHint)
            .foregroundStyle(.secondary)
        }
      }
      if !signal.signal.payload.relatedFiles.isEmpty {
        InspectorSection(title: "Related Files") {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(signal.signal.payload.relatedFiles.enumerated()), id: \.offset) { _, path in
              Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
          }
        }
      }
      InspectorSection(title: "Metadata") {
        Text(verbatim: signal.signal.payload.metadata.prettyPrintedJSONString())
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      if let acknowledgment = signal.acknowledgment {
        InspectorSection(title: "Acknowledgment") {
          InspectorFactGrid(
            facts: [
              .init(title: "Result", value: acknowledgment.result.title),
              .init(title: "Agent", value: acknowledgment.agent),
              .init(title: "At", value: formatTimestamp(acknowledgment.acknowledgedAt)),
            ]
          )
          if let details = acknowledgment.details, !details.isEmpty {
            Text(details)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessAccessibility.signalInspectorCard,
      label: signal.signal.command,
      value: signal.signal.signalId
    )
    .accessibilityFrameMarker("\(HarnessAccessibility.signalInspectorCard).frame")
  }
}
