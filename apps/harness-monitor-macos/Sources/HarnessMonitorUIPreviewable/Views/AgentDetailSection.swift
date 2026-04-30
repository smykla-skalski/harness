import HarnessMonitorKit
import SwiftUI

struct AgentDetailSection: View {
  @Environment(\.openWindow)
  private var openWindow
  let store: HarnessMonitorStore
  let agent: AgentRegistration
  let activity: AgentToolActivitySummary?
  let runtimePresentation: AcpRuntimePresentation
  @State private var signalCommand = "inject_context"
  @State private var signalMessage = ""
  @State private var signalActionHint = ""
  @State private var selectedRole: SessionRole = .worker

  init(
    store: HarnessMonitorStore,
    agent: AgentRegistration,
    activity: AgentToolActivitySummary?,
    runtimePresentation: AcpRuntimePresentation = .full
  ) {
    self.store = store
    self.agent = agent
    self.activity = activity
    self.runtimePresentation = runtimePresentation
  }

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
      .init(title: "Current Task", value: currentTaskTitle),
      .init(title: "Last Activity", value: formatTimestamp(agent.lastActivityAt)),
      .init(
        title: "Pickup Time",
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

  private var currentTaskTitle: String {
    guard
      let currentTaskID = agent.currentTaskId,
      let task = store.selectedSession?.tasks.first(where: { $0.taskId == currentTaskID })
    else {
      return agent.currentTaskId ?? "Idle"
    }
    return task.title
  }

  private var agentTimelineEntries: [TimelineEntry] {
    Array(store.timeline.filter { $0.agentId == agent.agentId }.prefix(8))
  }

  private var pendingDecisionAttention: AcpDecisionAttention? {
    store.acpDecisionAttention(for: agent.agentId)
  }

  private var acpRuntimeState: AcpAgentRuntimeState? {
    store.acpRuntimeState(for: agent.agentId)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      if let pendingDecisionAttention {
        AgentDetailAwaitingDecisionStrip(
          count: pendingDecisionAttention.count,
          buttonAccessibilityIdentifier:
            HarnessMonitorAccessibility
            .agentDetailOpenDecisionsButton(agent.agentId)
        ) {
          openPendingDecisions()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.agentDetailAwaitingDecisionStrip(agent.agentId)
        )
        .accessibilityTestProbe(
          HarnessMonitorAccessibility.agentDetailAwaitingDecisionStrip(agent.agentId),
          label: "Awaiting decision",
          value:
            "count=\(pendingDecisionAttention.count) batch=\(pendingDecisionAttention.oldestBatchID)"
        )
        .accessibilityTestProbe(
          HarnessMonitorAccessibility.agentsWindowDetailAwaitingDecisionState,
          label:
            "count=\(pendingDecisionAttention.count) batch=\(pendingDecisionAttention.oldestBatchID)",
          value: agent.agentId
        )
      }
      if let acpRuntimeState {
        runtimeView(runtimeState: acpRuntimeState)
      }
      Text(agent.name)
        .scaledFont(.system(.title3, design: .rounded, weight: .bold))
      Text("\(runtimeDisplayLabel(agent.runtime)) • \(agent.role.title)")
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
        InspectorSection(title: "Activity Summary") {
          InspectorFactGrid(
            facts: [
              .init(title: "Actions", value: "\(activity.toolInvocationCount)"),
              .init(title: "Results", value: "\(activity.toolResultCount)"),
              .init(title: "Issues", value: "\(activity.toolErrorCount)"),
              .init(title: "Latest Action", value: activity.latestToolName ?? "Unknown"),
            ]
          )
          if !activity.recentTools.isEmpty {
            Text("Recent Activity")
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
                  Text(humanizedWorkspaceLabel(entry.kind))
                    .scaledFont(.caption.weight(.semibold))
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
      InspectorSection(title: "Send Update") {
        Text("Share a short instruction or context update with this agent.")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
        TextField("Update Type", text: $signalCommand)
          .harnessNativeFormControl()
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentsWindowDetailSignalCommand)
          .submitLabel(.send)
        TextField("Message", text: $signalMessage, axis: .vertical)
          .harnessNativeFormControl()
          .lineLimit(3, reservesSpace: true)
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentsWindowDetailSignalMessage)
          .submitLabel(.send)
        TextField("Optional Context", text: $signalActionHint)
          .harnessNativeFormControl()
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentsWindowDetailSignalAction)
          .submitLabel(.send)
        HarnessInlineActionButton(
          title: "Send Update",
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

  @ViewBuilder
  private func runtimeView(runtimeState: AcpAgentRuntimeState) -> some View {
    AcpRuntimeView(
      runtimeState: runtimeState,
      presentation: runtimePresentation
    )
  }

  private func changeRole() async {
    _ = await store.changeRole(agentID: agent.agentId, role: effectiveSelectedRole)
    selectedRole = agent.role
  }

  private func openPendingDecisions() {
    let oldestOpenDecisionID = store.supervisorOpenDecisions
      .filter { $0.agentID == agent.agentId }
      .min {
        if $0.createdAt != $1.createdAt {
          return $0.createdAt < $1.createdAt
        }
        return $0.id < $1.id
      }?.id

    if let decisionID = oldestOpenDecisionID ?? store.selectOldestDecision(for: agent.agentId) {
      store.supervisorSelectedDecisionID = decisionID
      store.requestPrimaryDecisionActionFocus(decisionID: decisionID)
    }
    openWindow(id: HarnessMonitorWindowID.workspace)
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
