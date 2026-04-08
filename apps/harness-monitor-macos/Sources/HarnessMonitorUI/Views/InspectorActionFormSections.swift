import HarnessMonitorKit
import SwiftUI

struct InspectorActionStatusBanner: View {
  let isSessionReadOnly: Bool
  let isSessionActionInFlight: Bool
  let lastAction: String
  let lastError: String?
  let availableActionActors: [AgentRegistration]
  @Binding var actionActorID: String

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      HStack {
        Label("Action Console", systemImage: "dial.high")
          .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        Spacer()
        if isSessionActionInFlight {
          HarnessMonitorSpinner()
            .transition(.opacity)
        } else if !lastAction.isEmpty {
          Text(lastAction)
            .scaledFont(.caption.bold())
            .foregroundStyle(HarnessMonitorTheme.success)
            .accessibilityIdentifier(HarnessMonitorAccessibility.actionToast)
            .transition(.opacity)
        }
      }
      .animation(.spring(duration: 0.2), value: isSessionActionInFlight)
      .animation(.spring(duration: 0.2), value: lastAction.isEmpty)
      Text(statusMessage)
      .scaledFont(.system(.footnote, design: .rounded, weight: .medium))
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .lineLimit(3)
      if !availableActionActors.isEmpty {
        Picker("Act As", selection: $actionActorID) {
          ForEach(availableActionActors) { agent in
            Text(agent.name).tag(agent.agentId)
          }
        }
        .pickerStyle(.menu)
        .harnessNativeFormControl()
        .labelsHidden()
        .accessibilityLabel("Act As")
        .accessibilityIdentifier(HarnessMonitorAccessibility.actionActorPicker)
      }
      if let lastError, !lastError.isEmpty {
        Text("Action failed: \(lastError)")
          .scaledFont(.system(.footnote, design: .rounded, weight: .semibold))
          .foregroundStyle(HarnessMonitorTheme.danger)
          .lineLimit(3)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var statusMessage: String {
    if isSessionReadOnly {
      return """
      The daemon is offline. Persisted session data remains visible, but daemon-backed
      actions are read-only.
      """
    }
    return """
    Task creation, reassignments, checkpoints, and leadership changes flow through
    the daemon.
    """
  }
}

struct InspectorCreateTaskSection: View {
  @Binding var createTitle: String
  @Binding var createContext: String
  @Binding var createSeverity: TaskSeverity
  let isSessionReadOnly: Bool
  let isSessionActionInFlight: Bool
  let submitCreateTask: () -> Void
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
      Button("Create Task", action: submitCreateTask)
        .harnessActionButtonStyle(variant: .prominent, tint: nil)
        .disabled(
          createTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || isSessionActionInFlight
            || isSessionReadOnly
        )
    }
    .disabled(isSessionReadOnly || isSessionActionInFlight)
  }
}

struct InspectorTaskActionsSection: View {
  let task: WorkItem
  let tasks: [WorkItem]
  let agents: [AgentRegistration]
  @Binding var taskID: String
  @Binding var assigneeID: String
  @Binding var taskStatus: TaskStatus
  @Binding var statusNote: String
  @Binding var checkpointSummary: String
  @Binding var checkpointProgress: Double
  let isSessionReadOnly: Bool
  let isSessionActionInFlight: Bool
  let assignSelectedTask: () -> Void
  let updateSelectedTask: () -> Void
  let checkpointSelectedTask: () -> Void
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
      HStack {
        Button("Assign", action: assignSelectedTask)
          .harnessActionButtonStyle(variant: .prominent, tint: nil)
          .disabled(isSessionActionInFlight || isSessionReadOnly)
      }
      HStack {
        Button("Update Status", action: updateSelectedTask)
          .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
          .disabled(isSessionActionInFlight || isSessionReadOnly)
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
      }
      HStack {
        Text("\(Int(checkpointProgress))%")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Spacer()
        Button("Save Checkpoint", action: checkpointSelectedTask)
          .harnessActionButtonStyle(variant: .prominent, tint: HarnessMonitorTheme.caution)
          .disabled(isSessionActionInFlight || isSessionReadOnly)
      }

      if let checkpoint = task.checkpointSummary {
        Text("Latest: \(checkpoint.progress)% · \(checkpoint.summary)")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    }
    .disabled(isSessionReadOnly || isSessionActionInFlight)
  }
}

struct InspectorRoleActionsSection: View {
  let store: HarnessMonitorStore
  let agent: AgentRegistration
  let leaderID: String?
  @Binding var role: SessionRole
  let isSessionReadOnly: Bool
  let isSessionActionInFlight: Bool
  let changeSelectedRole: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      HarnessMonitorActionHeader(
        title: "Role Actions",
        subtitle: "Change the selected agent role without leaving the inspector."
      )
      Text(agent.name)
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
      Picker("Role", selection: $role) {
        ForEach(SessionRole.allCases.filter { $0 != .leader }, id: \.self) { role in
          Text(role.title).tag(role)
        }
      }
      .harnessNativeFormControl()
      Button("Change Role", action: changeSelectedRole)
        .harnessActionButtonStyle(variant: .prominent, tint: nil)
        .disabled(isSessionActionInFlight || isSessionReadOnly)
      Button("Remove Agent") {
        store.requestRemoveAgentConfirmation(agentID: agent.agentId)
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .red)
      .disabled(agent.agentId == leaderID || isSessionActionInFlight || isSessionReadOnly)
      .help(agent.agentId == leaderID ? "The session leader cannot be removed" : "")
      .accessibilityIdentifier(HarnessMonitorAccessibility.removeAgentButton)
    }
    .disabled(isSessionReadOnly || isSessionActionInFlight)
  }
}

struct InspectorLeaderTransferSection: View {
  let detail: SessionDetail
  @Binding var transferLeaderID: String
  @Binding var transferReason: String
  let transferLeaderButtonTitle: String
  let actionActorID: String
  let isSessionReadOnly: Bool
  let isSessionActionInFlight: Bool
  let submitTransferLeader: () -> Void

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
      TextField("Reason", text: $transferReason, axis: .vertical)
        .harnessNativeFormControl()
        .lineLimit(3, reservesSpace: true)
        .submitLabel(.done)
      Button(transferLeaderButtonTitle, action: submitTransferLeader)
        .harnessActionButtonStyle(variant: .prominent, tint: HarnessMonitorTheme.caution)
        .disabled(
          transferLeaderID.isEmpty || transferLeaderID == detail.session.leaderId
            || isSessionActionInFlight
            || isSessionReadOnly
        )
        .help(
          transferLeaderID == detail.session.leaderId
            ? "Select a different agent to transfer leadership to" : ""
        )
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.leaderTransferSection)
    .disabled(isSingleAgent || isSessionReadOnly || isSessionActionInFlight)
    .opacity(isSingleAgent ? 0.4 : 1)
    .help(isSingleAgent ? "At least two agents are needed to transfer leadership" : "")
  }
}
