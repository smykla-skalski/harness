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
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      Text("Inspector")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Text(
        "Pick a task, agent, signal, or observe card from the cockpit to focus actions and detail here."
      )
      .foregroundStyle(HarnessTheme.secondaryInk)
      InspectorFactGrid(facts: facts)
      if !detail.agentActivity.isEmpty {
        InspectorSection(title: "Recent Agent Activity") {
          VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
            ForEach(detail.agentActivity.prefix(2)) { activity in
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Text(activity.agentId)
                    .scaledFont(.system(.subheadline, design: .rounded, weight: .semibold))
                  Spacer()
                  Text(activity.latestEventAt.map(formatTimestamp) ?? "No events")
                    .scaledFont(.caption.monospaced())
                    .foregroundStyle(HarnessTheme.secondaryInk)
                }
                Text(activity.recentTools.joined(separator: " · "))
                  .scaledFont(.caption)
                  .foregroundStyle(HarnessTheme.secondaryInk)
                  .lineLimit(2)
              }
              .harnessCellPadding()
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

  private var facts: [InspectorFact] {
    [
      .init(title: "Severity", value: task.severity.title),
      .init(title: "Status", value: task.status.title),
      .init(title: "Assignee", value: task.assignedTo ?? "Unassigned"),
      .init(title: "Source", value: task.source.title),
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      Text(task.title)
        .scaledFont(.system(.title3, design: .rounded, weight: .bold))
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
            .scaledFont(.subheadline)
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
          VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
            ForEach(task.notes) { note in
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Text(note.agentId ?? "system")
                    .scaledFont(.caption.bold())
                  Spacer()
                  Text(formatTimestamp(note.timestamp))
                    .scaledFont(.caption.monospaced())
                    .foregroundStyle(HarnessTheme.secondaryInk)
                }
                Text(note.text)
                  .scaledFont(.subheadline)
                  .foregroundStyle(HarnessTheme.secondaryInk)
              }
              .harnessCellPadding()
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      if let blockedReason = task.blockedReason, !blockedReason.isEmpty {
        InspectorSection(title: "Blocked Reason") {
          Text(blockedReason)
            .scaledFont(.subheadline)
            .foregroundStyle(HarnessTheme.danger)
        }
      }
      if let completedAt = task.completedAt {
        InspectorSection(title: "Completed") {
          Text(formatTimestamp(completedAt))
            .scaledFont(.subheadline.monospaced())
            .foregroundStyle(HarnessTheme.secondaryInk)
        }
      }
      InspectorSection(title: "Your Notes") {
        if let sessionID = store.selectedSession?.session.sessionId,
          store.isPersistenceAvailable {
          TaskUserNotesSection(
            store: store,
            taskID: task.taskId,
            sessionID: sessionID
          )
        } else {
          PersistenceUnavailableNotesState()
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
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      Text(agent.name)
        .scaledFont(.system(.title3, design: .rounded, weight: .bold))
      Text("\(agent.runtime) • \(agent.role.title)")
        .foregroundStyle(HarnessTheme.secondaryInk)
      InspectorFactGrid(facts: facts)
      DisclosureGroup("Runtime Capabilities") {
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
      .scaledFont(.caption.bold())
      .foregroundStyle(HarnessTheme.secondaryInk)
      DisclosureGroup("Declared Capabilities") {
        InspectorBadgeColumn(values: capabilityBadges)
      }
      .scaledFont(.caption.bold())
      .foregroundStyle(HarnessTheme.secondaryInk)
      if !agent.runtimeCapabilities.hookPoints.isEmpty {
        DisclosureGroup("Hook Points") {
          InspectorBadgeColumn(
            values: agent.runtimeCapabilities.hookPoints.map { hook in
              let context = hook.supportsContextInjection ? "context" : "no-context"
              return "\(hook.name) · \(hook.typicalLatencySeconds)s · \(context)"
            }
          )
        }
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessTheme.secondaryInk)
      }
      if let activity {
        DisclosureGroup("Tool Activity") {
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
              .scaledFont(.caption.bold())
              .foregroundStyle(HarnessTheme.secondaryInk)
            Text(activity.recentTools.joined(separator: " · "))
              .scaledFont(.caption)
              .foregroundStyle(HarnessTheme.secondaryInk)
          }
        }
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessTheme.secondaryInk)
      }
      InspectorSection(title: "Send Signal") {
        TextField("Command", text: $signalCommand)
          .submitLabel(.send)
        TextField("Message", text: $signalMessage, axis: .vertical)
          .lineLimit(3, reservesSpace: true)
          .submitLabel(.send)
        TextField("Action Hint", text: $signalActionHint)
          .submitLabel(.send)
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
        .disabled(
          signalCommand.isEmpty || signalMessage.isEmpty || store.isSessionActionInFlight
        )
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
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      Text(signal.signal.command)
        .scaledFont(.system(.title3, design: .rounded, weight: .bold))
      Text(signal.signal.payload.message)
        .foregroundStyle(HarnessTheme.secondaryInk)
      InspectorFactGrid(facts: facts)
      DisclosureGroup("Delivery") {
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
      .scaledFont(.caption.bold())
      .foregroundStyle(HarnessTheme.secondaryInk)
      if let actionHint = signal.signal.payload.actionHint, !actionHint.isEmpty {
        InspectorSection(title: "Action Hint") {
          Text(actionHint)
            .foregroundStyle(HarnessTheme.secondaryInk)
        }
      }
      if !signal.signal.payload.relatedFiles.isEmpty {
        DisclosureGroup("Related Files") {
          VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
            ForEach(Array(signal.signal.payload.relatedFiles.enumerated()), id: \.offset) { _, path in
              Text(path)
                .scaledFont(.caption.monospaced())
                .truncationMode(.middle)
                .foregroundStyle(HarnessTheme.secondaryInk)
                .lineLimit(2)
            }
          }
        }
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessTheme.secondaryInk)
      }
      DisclosureGroup("Metadata") {
        Text(verbatim: signal.signal.payload.metadata.prettyPrintedJSONString())
          .scaledFont(.caption.monospaced())
          .foregroundStyle(HarnessTheme.secondaryInk)
          .textSelection(.enabled)
      }
      .scaledFont(.caption.bold())
      .foregroundStyle(HarnessTheme.secondaryInk)
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
              .foregroundStyle(HarnessTheme.secondaryInk)
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
