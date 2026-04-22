import HarnessMonitorKit
import SwiftUI

struct InspectorActionStatusBanner: View {
  let unavailableMessage: String?
  let actionActorOptions: [AgentRegistration]
  @Binding var actionActorID: String

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      Label("Action Console", systemImage: "dial.high")
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(statusMessage)
        .scaledFont(.system(.footnote, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(3)
      if !actionActorOptions.isEmpty {
        Picker("Act As", selection: $actionActorID) {
          ForEach(actionActorOptions) { agent in
            Text(actionActorTitle(for: agent)).tag(agent.agentId)
          }
        }
        .pickerStyle(.menu)
        .harnessNativeFormControl()
        .labelsHidden()
        .accessibilityLabel("Act As")
        .accessibilityIdentifier(HarnessMonitorAccessibility.actionActorPicker)
      }
    }
  }

  private var statusMessage: String {
    if let unavailableMessage {
      return unavailableMessage
    }
    return """
      Task creation, reassignments, checkpoints, and leadership changes flow through
      the daemon.
      """
  }

  private func actionActorTitle(for agent: AgentRegistration) -> String {
    guard agent.status != .active else {
      return agent.name
    }
    return "\(agent.name) (\(agent.status.title.lowercased()))"
  }
}

struct InspectorCreateTaskSection: View {
  let store: HarnessMonitorStore
  let sessionID: String
  @Binding var createTitle: String
  @Binding var createContext: String
  @Binding var createSeverity: TaskSeverity
  let areSessionActionsAvailable: Bool
  let submitCreateTask: @MainActor @Sendable () -> Void
  @FocusState private var focusedField: ActionField?

  private enum ActionField: Hashable {
    case createTitle
    case createContext
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      HarnessMonitorActionHeader(
        title: "Create Task",
        subtitle: "Capture new work directly into the active session."
      )
      TextField("Title", text: $createTitle)
        .harnessNativeFormControl()
        .focused($focusedField, equals: .createTitle)
        .submitLabel(.next)
        .onSubmit { focusedField = .createContext }
        .accessibilityIdentifier(HarnessMonitorAccessibility.createTaskTitleField)
      TextField("Context", text: $createContext, axis: .vertical)
        .harnessNativeFormControl()
        .focused($focusedField, equals: .createContext)
        .lineLimit(4, reservesSpace: true)
        .submitLabel(.done)
      Picker("Severity", selection: $createSeverity) {
        ForEach(TaskSeverity.allCases, id: \.self) { severity in
          Text(severity.title).tag(severity)
        }
      }
      .harnessNativeFormControl()
      HarnessInlineActionButton(
        title: "Create Task",
        actionID: .createTask(sessionID: sessionID),
        store: store,
        variant: .prominent,
        tint: nil,
        isExternallyDisabled:
          createTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || !areSessionActionsAvailable,
        accessibilityIdentifier: HarnessMonitorAccessibility.createTaskButton,
        action: { submitCreateTask() }
      )
    }
    .disabled(!areSessionActionsAvailable)
  }
}

struct InspectorTaskActionsSection: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let task: WorkItem
  let tasks: [WorkItem]
  let agents: [AgentRegistration]
  @Binding var taskID: String
  @Binding var assigneeID: String
  @Binding var taskStatus: TaskStatus
  @Binding var queuePolicy: TaskQueuePolicy
  @Binding var statusNote: String
  @Binding var checkpointSummary: String
  @Binding var checkpointProgress: Double
  let areSessionActionsAvailable: Bool
  let assignSelectedTask: @MainActor @Sendable () -> Void
  let updateQueuePolicy: @MainActor @Sendable () -> Void
  let updateSelectedTask: @MainActor @Sendable () -> Void
  let checkpointSelectedTask: @MainActor @Sendable () -> Void
  @FocusState private var focusedField: ActionField?

  private enum ActionField: Hashable {
    case statusNote
    case checkpointSummary
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      HarnessMonitorActionHeader(
        title: "Task Actions",
        subtitle: "Reassign, update status, or checkpoint the selected task."
      )
      Picker("Task", selection: $taskID) {
        ForEach(tasks) { item in
          Text(item.title).tag(item.taskId)
        }
      }
      .harnessNativeFormControl()
      Picker("Assignee", selection: $assigneeID) {
        ForEach(agents) { agent in
          Text(agent.name).tag(agent.agentId)
        }
      }
      .harnessNativeFormControl()
      Picker("Status", selection: $taskStatus) {
        ForEach(TaskStatus.allCases, id: \.self) { status in
          Text(status.title).tag(status)
        }
      }
      .harnessNativeFormControl()
      Picker("Queue Policy", selection: $queuePolicy) {
        ForEach(TaskQueuePolicy.allCases, id: \.self) { policy in
          Text(policy.title).tag(policy)
        }
      }
      .harnessNativeFormControl()
      HStack {
        HarnessInlineActionButton(
          title: "Assign",
          actionID: .assignTask(sessionID: sessionID, taskID: task.taskId),
          store: store,
          variant: .prominent,
          tint: nil,
          isExternallyDisabled: !areSessionActionsAvailable,
          accessibilityIdentifier: HarnessMonitorAccessibility.assignTaskButton,
          action: { assignSelectedTask() }
        )
        HarnessInlineActionButton(
          title: "Save Queue Policy",
          actionID: .updateTaskQueuePolicy(sessionID: sessionID, taskID: task.taskId),
          store: store,
          variant: .bordered,
          tint: .secondary,
          isExternallyDisabled: !areSessionActionsAvailable,
          accessibilityIdentifier: HarnessMonitorAccessibility.updateTaskQueuePolicyButton,
          action: { updateQueuePolicy() }
        )
      }
      HStack {
        HarnessInlineActionButton(
          title: "Update Status",
          actionID: .updateTaskStatus(sessionID: sessionID, taskID: task.taskId),
          store: store,
          variant: .bordered,
          tint: .secondary,
          isExternallyDisabled: !areSessionActionsAvailable,
          accessibilityIdentifier: HarnessMonitorAccessibility.updateTaskStatusButton,
          action: { updateSelectedTask() }
        )
        TextField("Update note", text: $statusNote, axis: .vertical)
          .harnessNativeFormControl()
          .focused($focusedField, equals: .statusNote)
          .lineLimit(2, reservesSpace: true)
          .submitLabel(.done)
      }

      Divider()

      Text("Checkpoint")
        .scaledFont(.headline)
      TextField("Summary", text: $checkpointSummary, axis: .vertical)
        .harnessNativeFormControl()
        .focused($focusedField, equals: .checkpointSummary)
        .lineLimit(3, reservesSpace: true)
        .submitLabel(.done)
      LabeledContent("Progress") {
        Slider(value: $checkpointProgress, in: 0...100, step: 5)
          .harnessNativeFormControl()
          .accessibilityValue("\(Int(checkpointProgress)) percent complete")
          .accessibilityHint("Sets the completion percentage for this checkpoint")
      }
      HStack {
        Text("\(Int(checkpointProgress))%")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Spacer()
        HarnessInlineActionButton(
          title: "Save Checkpoint",
          actionID: .checkpointTask(sessionID: sessionID, taskID: task.taskId),
          store: store,
          variant: .prominent,
          tint: HarnessMonitorTheme.caution,
          isExternallyDisabled: !areSessionActionsAvailable,
          accessibilityIdentifier: HarnessMonitorAccessibility.checkpointTaskButton,
          action: { checkpointSelectedTask() }
        )
      }

      if let checkpoint = task.checkpointSummary {
        Text("Latest: \(checkpoint.progress)% · \(checkpoint.summary)")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    }
    .disabled(!areSessionActionsAvailable)
  }
}

struct InspectorRoleActionsSection: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let agent: AgentRegistration
  let leaderID: String?
  @Binding var role: SessionRole
  let areSessionActionsAvailable: Bool
  let changeSelectedRole: @MainActor @Sendable () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      HarnessMonitorActionHeader(
        title: "Role Actions",
        subtitle: "Change the selected agent role without leaving the inspector."
      )
      Text(agent.name)
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
      if agent.agentId == leaderID {
        Text("Transfer leadership before changing the leader's role.")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      } else {
        Picker("Role", selection: $role) {
          ForEach(SessionRole.allCases.filter { $0 != .leader }, id: \.self) { role in
            Text(role.title).tag(role)
          }
        }
        .harnessNativeFormControl()
        HarnessInlineActionButton(
          title: "Change Role",
          actionID: .changeRole(sessionID: sessionID, agentID: agent.agentId),
          store: store,
          variant: .prominent,
          tint: nil,
          isExternallyDisabled: !areSessionActionsAvailable,
          accessibilityIdentifier: HarnessMonitorAccessibility.changeRoleButton,
          action: { changeSelectedRole() }
        )
      }
      HarnessInlineActionButton(
        title: "Remove Agent",
        actionID: .removeAgent(sessionID: sessionID, agentID: agent.agentId),
        store: store,
        variant: .bordered,
        tint: .red,
        isExternallyDisabled: agent.agentId == leaderID || !areSessionActionsAvailable,
        accessibilityIdentifier: HarnessMonitorAccessibility.removeAgentButton,
        help: agent.agentId == leaderID ? "The session leader cannot be removed" : "",
        action: { store.requestRemoveAgentConfirmation(agentID: agent.agentId) }
      )
    }
    .disabled(!areSessionActionsAvailable)
  }
}

struct InspectorLeaderTransferSection: View {
  let store: HarnessMonitorStore
  let detail: SessionDetail
  @Binding var transferLeaderID: String
  @Binding var transferReason: String
  let transferLeaderButtonTitle: String
  let actionActorID: String
  let areSessionActionsAvailable: Bool
  let submitTransferLeader: @MainActor @Sendable () -> Void

  private var isSingleAgent: Bool {
    detail.agents.count <= 1
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      HarnessMonitorActionHeader(
        title: "Leader Transfer",
        subtitle: "Promote a live agent to leader when the current leader needs to step away."
      )
      if let pendingTransfer = detail.session.pendingLeaderTransfer {
        let timestamp = formatTimestamp(pendingTransfer.requestedAt)
        Text(
          "\(pendingTransfer.requestedBy) requested \(pendingTransfer.newLeaderId) at \(timestamp)."
        )
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      if detail.agents.isEmpty {
        Text("Agent availability is still loading for this session.")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      } else {
        Picker("New Leader", selection: $transferLeaderID) {
          if let leader = detail.agents.first(where: { $0.agentId == detail.session.leaderId }) {
            Text("\(leader.name) (current leader)")
              .foregroundStyle(.tertiary)
              .tag(leader.agentId)
          }
          ForEach(detail.agents.filter { $0.agentId != detail.session.leaderId }) { agent in
            Text(agent.name).tag(agent.agentId)
          }
        }
        .onChange(of: transferLeaderID) { previous, current in
          if current == detail.session.leaderId, previous != detail.session.leaderId {
            transferLeaderID = previous
          }
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.leaderTransferPicker)
        .harnessNativeFormControl()
      }
      TextField("Reason", text: $transferReason, axis: .vertical)
        .harnessNativeFormControl()
        .lineLimit(3, reservesSpace: true)
        .submitLabel(.done)
      HarnessInlineActionButton(
        title: transferLeaderButtonTitle,
        actionID: .transferLeader(
          sessionID: detail.session.sessionId,
          newLeaderID: transferLeaderID
        ),
        store: store,
        variant: .prominent,
        tint: HarnessMonitorTheme.caution,
        isExternallyDisabled:
          transferLeaderID.isEmpty || transferLeaderID == detail.session.leaderId
          || !areSessionActionsAvailable,
        help:
          transferLeaderID == detail.session.leaderId
          ? "Select a different agent to transfer leadership to" : "",
        action: { submitTransferLeader() }
      )
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.leaderTransferSection)
    .disabled(isSingleAgent || !areSessionActionsAvailable)
    .opacity(isSingleAgent ? 0.4 : 1)
    .help(isSingleAgent ? "At least two agents are needed to transfer leadership" : "")
  }
}
