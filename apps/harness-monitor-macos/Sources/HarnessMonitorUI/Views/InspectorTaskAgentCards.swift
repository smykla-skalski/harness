import HarnessMonitorKit
import SwiftUI

struct TaskInspectorCard: View {
  let store: HarnessMonitorStore
  let task: WorkItem
  let notesSessionID: String?
  let isPersistenceAvailable: Bool

  private var facts: [InspectorFact] {
    [
      .init(title: "Severity", value: task.severity.title),
      .init(title: "Status", value: task.status.title),
      .init(title: "Assignee", value: task.assignmentSummary),
      .init(title: "Queue Policy", value: task.queuePolicy.title),
      .init(title: "Source", value: task.source.title),
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text(task.title)
        .scaledFont(.system(.title3, design: .rounded, weight: .bold))
      Text(task.context ?? "No task context provided.")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
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
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
      if let suggestion = task.suggestedFix {
        InspectorSection(title: "Suggested Fix") {
          Text(suggestion)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
      if !task.notes.isEmpty {
        InspectorSection(title: "Notes") {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
            ForEach(task.notes) { note in
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Text(note.agentId ?? "system")
                    .scaledFont(.caption.bold())
                  Spacer()
                  Text(formatTimestamp(note.timestamp))
                    .scaledFont(.caption.monospaced())
                    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                }
                Text(note.text)
                  .scaledFont(.subheadline)
                  .foregroundStyle(HarnessMonitorTheme.secondaryInk)
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
            .foregroundStyle(HarnessMonitorTheme.danger)
        }
      }
      if let completedAt = task.completedAt {
        InspectorSection(title: "Completed") {
          Text(formatTimestamp(completedAt))
            .scaledFont(.subheadline.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
      InspectorSection(title: "Your Notes") {
        if let notesSessionID, isPersistenceAvailable {
          TaskUserNotesSection(
            store: store,
            taskID: task.taskId,
            sessionID: notesSessionID
          )
        } else {
          PersistenceUnavailableNotesState()
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.taskInspectorCard,
      label: task.title,
      value: task.taskId
    )
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.taskInspectorCard).frame")
  }
}

struct AgentInspectorCard: View {
  let store: HarnessMonitorStore
  let agent: AgentRegistration
  let activity: AgentToolActivitySummary?
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
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text(agent.name)
        .scaledFont(.system(.title3, design: .rounded, weight: .bold))
      Text("\(agent.runtime) • \(agent.role.title)")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
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
              .scaledFont(.caption.bold())
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            Text(activity.recentTools.joined(separator: " · "))
              .scaledFont(.caption)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          }
        }
      }
      InspectorSection(title: "Send Signal") {
        TextField("Command", text: $signalCommand)
          .harnessNativeFormControl()
          .accessibilityIdentifier(HarnessMonitorAccessibility.signalCommandField)
          .submitLabel(.send)
        TextField("Message", text: $signalMessage, axis: .vertical)
          .harnessNativeFormControl()
          .lineLimit(3, reservesSpace: true)
          .accessibilityIdentifier(HarnessMonitorAccessibility.signalMessageField)
          .submitLabel(.send)
        TextField("Action Hint", text: $signalActionHint)
          .harnessNativeFormControl()
          .submitLabel(.send)
        HarnessInlineActionButton(
          title: "Send Signal",
          actionID: .sendSignal(
            sessionID: store.selectedSessionID ?? "",
            agentID: agent.agentId
          ),
          store: store,
          variant: .prominent,
          tint: nil,
          isExternallyDisabled:
            signalCommand.isEmpty || signalMessage.isEmpty
            || store.isSessionReadOnly,
          accessibilityIdentifier: HarnessMonitorAccessibility.signalSendButton,
          action: {
            Task {
              await store.sendSignal(
                agentID: agent.agentId,
                command: signalCommand,
                message: signalMessage,
                actionHint: signalActionHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  ? nil : signalActionHint
              )
            }
          }
        )
      }
      .disabled(store.isSessionReadOnly)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.agentInspectorCard,
      label: agent.name,
      value: agent.agentId
    )
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.agentInspectorCard).frame")
  }
}
