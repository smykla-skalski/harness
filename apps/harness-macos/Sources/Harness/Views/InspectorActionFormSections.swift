import HarnessKit
import SwiftUI

struct InspectorActionStatusBanner: View {
  let isSessionActionInFlight: Bool
  let lastAction: String
  let lastError: String?
  let availableActionActors: [AgentRegistration]
  @Binding var actionActorID: String

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
      HStack {
        Label("Action Console", systemImage: "dial.high")
          .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        Spacer()
        if isSessionActionInFlight {
          HarnessSpinner()
            .transition(.opacity)
        } else if !lastAction.isEmpty {
          Text(lastAction)
            .scaledFont(.caption.bold())
            .foregroundStyle(HarnessTheme.success)
            .accessibilityIdentifier(HarnessAccessibility.actionToast)
            .transition(.opacity)
        }
      }
      .animation(.spring(duration: 0.2), value: isSessionActionInFlight)
      .animation(.spring(duration: 0.2), value: lastAction.isEmpty)
      Text(
        "Task creation, reassignments, checkpoints, and leadership changes flow through the daemon."
      )
      .scaledFont(.system(.footnote, design: .rounded, weight: .medium))
      .foregroundStyle(HarnessTheme.secondaryInk)
      .lineLimit(3)
      if !availableActionActors.isEmpty {
        Picker("Act As", selection: $actionActorID) {
          ForEach(availableActionActors) { agent in
            Text(agent.name).tag(agent.agentId)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel("Act As")
        .accessibilityIdentifier(HarnessAccessibility.actionActorPicker)
      }
      if let lastError, !lastError.isEmpty {
        Text("Action failed: \(lastError)")
          .scaledFont(.system(.footnote, design: .rounded, weight: .semibold))
          .foregroundStyle(HarnessTheme.danger)
          .lineLimit(3)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

struct InspectorCreateTaskSection: View {
  @Binding var createTitle: String
  @Binding var createContext: String
  @Binding var createSeverity: TaskSeverity
  let isSessionActionInFlight: Bool
  let submitCreateTask: () -> Void
  @FocusState private var focusedField: ActionField?

  private enum ActionField: Hashable {
    case createTitle
    case createContext
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      HarnessActionHeader(
        title: "Create Task",
        subtitle: "Capture new work directly into the active session."
      )
      TextField("Title", text: $createTitle)
        .focused($focusedField, equals: .createTitle)
        .submitLabel(.next)
        .onSubmit { focusedField = .createContext }
      TextField("Context", text: $createContext, axis: .vertical)
        .focused($focusedField, equals: .createContext)
        .lineLimit(4, reservesSpace: true)
        .submitLabel(.done)
      Picker("Severity", selection: $createSeverity) {
        ForEach(TaskSeverity.allCases, id: \.self) { severity in
          Text(severity.title).tag(severity)
        }
      }
      Button("Create Task", action: submitCreateTask)
        .harnessActionButtonStyle(variant: .prominent, tint: nil)
        .disabled(
          createTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || isSessionActionInFlight
        )
    }
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
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      HarnessActionHeader(
        title: "Task Actions",
        subtitle: "Reassign, update status, or checkpoint the selected task."
      )
      Picker("Task", selection: $taskID) {
        ForEach(tasks) { item in
          Text(item.title).tag(item.taskId)
        }
      }
      Picker("Assignee", selection: $assigneeID) {
        ForEach(agents) { agent in
          Text(agent.name).tag(agent.agentId)
        }
      }
      Picker("Status", selection: $taskStatus) {
        ForEach(TaskStatus.allCases, id: \.self) { status in
          Text(status.title).tag(status)
        }
      }
      HStack {
        Button("Assign", action: assignSelectedTask)
          .harnessActionButtonStyle(variant: .prominent, tint: nil)
          .disabled(isSessionActionInFlight)
      }
      HStack {
        Button("Update Status", action: updateSelectedTask)
          .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
          .disabled(isSessionActionInFlight)
        TextField("Update note", text: $statusNote, axis: .vertical)
          .focused($focusedField, equals: .statusNote)
          .lineLimit(2, reservesSpace: true)
          .submitLabel(.done)
      }

      Divider()

      Text("Checkpoint")
        .scaledFont(.headline)
      TextField("Summary", text: $checkpointSummary, axis: .vertical)
        .focused($focusedField, equals: .checkpointSummary)
        .lineLimit(3, reservesSpace: true)
        .submitLabel(.done)
      LabeledContent("Progress") {
        Slider(value: $checkpointProgress, in: 0...100, step: 5)
      }
      HStack {
        Text("\(Int(checkpointProgress))%")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessTheme.secondaryInk)
        Spacer()
        Button("Save Checkpoint", action: checkpointSelectedTask)
          .harnessActionButtonStyle(variant: .prominent, tint: HarnessTheme.caution)
          .disabled(isSessionActionInFlight)
      }

      if let checkpoint = task.checkpointSummary {
        Text("Latest: \(checkpoint.progress)% · \(checkpoint.summary)")
          .scaledFont(.caption)
          .foregroundStyle(HarnessTheme.secondaryInk)
      }
    }
  }
}

struct InspectorRoleActionsSection: View {
  let agent: AgentRegistration
  let leaderID: String?
  @Binding var role: SessionRole
  let isSessionActionInFlight: Bool
  let changeSelectedRole: () -> Void
  let requestRemoveAgentConfirmation: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      HarnessActionHeader(
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
      Button("Change Role", action: changeSelectedRole)
        .harnessActionButtonStyle(variant: .prominent, tint: nil)
        .disabled(isSessionActionInFlight)
      Button("Remove Agent") {
        requestRemoveAgentConfirmation(agent.agentId)
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .red)
      .disabled(agent.agentId == leaderID || isSessionActionInFlight)
      .help(agent.agentId == leaderID ? "The session leader cannot be removed" : "")
      .accessibilityIdentifier(HarnessAccessibility.removeAgentButton)
    }
  }
}

struct InspectorLeaderTransferSection: View {
  let detail: SessionDetail
  @Binding var transferLeaderID: String
  @Binding var transferReason: String
  let transferLeaderButtonTitle: String
  let actionActorID: String
  let isSessionActionInFlight: Bool
  let submitTransferLeader: () -> Void
  @FocusState private var isReasonFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      HarnessActionHeader(
        title: "Leader Transfer",
        subtitle: "Promote a live agent to leader when the current leader needs to step away."
      )
      if let pendingTransfer = detail.session.pendingLeaderTransfer {
        let timestamp = formatTimestamp(pendingTransfer.requestedAt)
        Text(
          "\(pendingTransfer.requestedBy) requested \(pendingTransfer.newLeaderId) at \(timestamp)."
        )
        .scaledFont(.caption)
        .foregroundStyle(HarnessTheme.secondaryInk)
      }
      Picker("New Leader", selection: $transferLeaderID) {
        ForEach(detail.agents) { agent in
          Text(agent.name).tag(agent.agentId)
        }
      }
      TextField("Reason", text: $transferReason, axis: .vertical)
        .focused($isReasonFocused)
        .lineLimit(3, reservesSpace: true)
        .submitLabel(.done)
      Button(transferLeaderButtonTitle, action: submitTransferLeader)
        .harnessActionButtonStyle(variant: .prominent, tint: HarnessTheme.caution)
        .disabled(
          transferLeaderID.isEmpty || transferLeaderID == detail.session.leaderId
            || isSessionActionInFlight
        )
        .help(
          transferLeaderID == detail.session.leaderId
            ? "Select a different agent to transfer leadership to" : ""
        )
    }
  }
}
