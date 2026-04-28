import HarnessMonitorKit
import SwiftUI

struct AgentDetailSection: View {
  let store: HarnessMonitorStore
  let agent: AgentRegistration
  let activity: AgentToolActivitySummary?
  @State private var signalCommand = "inject_context"
  @State private var signalMessage = ""
  @State private var signalActionHint = ""
  @State private var selectedRole: SessionRole = .worker

  private var sessionID: String { store.selectedSessionID ?? "" }
  private var leaderID: String? { store.selectedSession?.session.leaderId }
  private var isLeader: Bool { agent.agentId == leaderID }
  private var roleActionsAvailable: Bool { store.areSelectedLeaderActionsAvailable }
  private var roleStateKey: String {
    "\(agent.agentId)|\(agent.role.rawValue)|\(leaderID ?? "-")"
  }
  private var rolePickerSelection: Binding<SessionRole> {
    Binding(
      get: {
        Self.normalizedRoleSelection(
          draftRole: selectedRole,
          agentRole: agent.role
        )
      },
      set: { selectedRole = $0 }
    )
  }
  private var rolePickerValues: [SessionRole] {
    Self.rolePickerOptions(for: agent.role)
  }
  private var effectiveSelectedRole: SessionRole {
    Self.submittedRoleSelection(
      draftRole: selectedRole,
      agentRole: agent.role
    )
  }

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

  private var assignedTasks: [WorkItem] {
    (store.selectedSession?.tasks ?? []).filter { $0.assignedTo == agent.agentId }
  }

  private var agentTimelineEntries: [TimelineEntry] {
    Array(store.timeline.filter { $0.agentId == agent.agentId }.prefix(8))
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
      InspectorSection(title: "Persona") {
        if let persona = agent.persona {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
            Text(persona.name)
              .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
            Text(persona.description)
              .scaledFont(.subheadline)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          }
        } else {
          Text("No persona assigned")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentsWindowDetailPersona)
      InspectorSection(title: "Assigned Tasks") {
        if assignedTasks.isEmpty {
          Text("No assigned tasks")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        } else {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
            ForEach(assignedTasks) { task in
              VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                  .scaledFont(.system(.subheadline, design: .rounded, weight: .semibold))
                Text(task.status.title)
                  .scaledFont(.caption)
                  .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              }
            }
          }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentsWindowDetailAssignedTasks)
      InspectorSection(title: "Recent Activity") {
        if agentTimelineEntries.isEmpty {
          Text("No recent activity")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        } else {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
            ForEach(agentTimelineEntries) { entry in
              VStack(alignment: .leading, spacing: 2) {
                Text(entry.summary)
                  .scaledFont(.subheadline)
                HStack(spacing: HarnessMonitorTheme.spacingXS) {
                  Text(entry.kind)
                    .scaledFont(.caption.monospaced())
                    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                  Text(formatTimestamp(entry.recordedAt))
                    .scaledFont(.caption)
                    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                }
              }
            }
          }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentsWindowDetailTimeline)
      InspectorSection(title: "Role Actions") {
        if isLeader {
          Text("Transfer leadership before changing the leader's role.")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        } else {
          Picker("Role", selection: rolePickerSelection) {
            ForEach(rolePickerValues, id: \.self) { role in
              Text(role.title).tag(role)
            }
          }
          .harnessNativeFormControl()
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentsWindowDetailRolePicker)
          HarnessInlineActionButton(
            title: "Change Role",
            actionID: .changeRole(sessionID: sessionID, agentID: agent.agentId),
            store: store,
            variant: .prominent,
            tint: nil,
            isExternallyDisabled: !roleActionsAvailable,
            accessibilityIdentifier: HarnessMonitorAccessibility.agentsWindowDetailRoleChange,
            action: {
              Task { await changeRole() }
            }
          )
        }
        HarnessInlineActionButton(
          title: "Remove Agent",
          actionID: .removeAgent(sessionID: sessionID, agentID: agent.agentId),
          store: store,
          variant: .bordered,
          tint: .red,
          isExternallyDisabled: isLeader || !roleActionsAvailable,
          accessibilityIdentifier: HarnessMonitorAccessibility.agentsWindowDetailRoleRemove,
          help: isLeader ? "The session leader cannot be removed" : "",
          action: { store.requestRemoveAgentConfirmation(agentID: agent.agentId) }
        )
      }
      .disabled(!roleActionsAvailable)
      .task(id: roleStateKey) {
        selectedRole = agent.role
      }
      InspectorSection(title: "Send Signal") {
        TextField("Command", text: $signalCommand)
          .harnessNativeFormControl()
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentsWindowDetailSignalCommand)
          .submitLabel(.send)
        TextField("Message", text: $signalMessage, axis: .vertical)
          .harnessNativeFormControl()
          .lineLimit(3, reservesSpace: true)
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentsWindowDetailSignalMessage)
          .submitLabel(.send)
        TextField("Action Hint", text: $signalActionHint)
          .harnessNativeFormControl()
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentsWindowDetailSignalAction)
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
          accessibilityIdentifier: HarnessMonitorAccessibility.agentsWindowDetailSignalSend,
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
      HarnessMonitorAccessibility.agentsWindowDetailCard,
      label: agent.name,
      value: agent.agentId
    )
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.agentsWindowDetailCard).frame")
  }

  private func changeRole() async {
    _ = await store.changeRole(agentID: agent.agentId, role: effectiveSelectedRole)
    selectedRole = agent.role
  }

  static func submittedRoleSelection(
    draftRole: SessionRole,
    agentRole: SessionRole
  ) -> SessionRole {
    normalizedRoleSelection(
      draftRole: draftRole,
      agentRole: agentRole
    )
  }

  static func normalizedRoleSelection(
    draftRole: SessionRole,
    agentRole: SessionRole
  ) -> SessionRole {
    let availableRoles = rolePickerOptions(for: agentRole)
    if availableRoles.contains(draftRole) {
      return draftRole
    }
    if availableRoles.contains(agentRole) {
      return agentRole
    }
    return availableRoles.first ?? agentRole
  }

  static func rolePickerOptions(for agentRole: SessionRole) -> [SessionRole] {
    if agentRole == .leader {
      return SessionRole.allCases
    }
    return SessionRole.allCases.filter { $0 != .leader }
  }
}
