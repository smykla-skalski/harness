import HarnessMonitorKit
import SwiftUI

struct InspectorCreateTaskConsole: View {
  let isSessionReadOnly: Bool
  let isSessionActionInFlight: Bool
  let createTaskAction: (String, String?, TaskSeverity) async -> Bool

  @State private var createTitle = ""
  @State private var createContext = ""
  @State private var createSeverity: TaskSeverity = .medium

  var body: some View {
    InspectorCreateTaskSection(
      createTitle: $createTitle,
      createContext: $createContext,
      createSeverity: $createSeverity,
      isSessionReadOnly: isSessionReadOnly,
      isSessionActionInFlight: isSessionActionInFlight,
      submitCreateTask: submitCreateTask
    )
  }

  private func submitCreateTask() {
    Task { await createTask() }
  }

  private func createTask() async {
    let title = createTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let context = createContext.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      return
    }

    let success = await createTaskAction(
      title,
      context.isEmpty ? nil : context,
      createSeverity
    )
    if success {
      createTitle = ""
      createContext = ""
      createSeverity = .medium
    }
  }
}

struct InspectorTaskMutationConsole: View {
  let selectedTask: WorkItem
  let tasks: [WorkItem]
  let agents: [AgentRegistration]
  let isSessionReadOnly: Bool
  let isSessionActionInFlight: Bool
  let assignTaskAction: (String, String) async -> Bool
  let updateTaskStatusAction: (String, TaskStatus, String?) async -> Bool
  let checkpointTaskAction: (String, String, Int) async -> Bool

  @State private var taskID = ""
  @State private var assigneeID = ""
  @State private var taskStatus: TaskStatus = .inProgress
  @State private var statusNote = ""
  @State private var checkpointSummary = ""
  @State private var checkpointProgress: Double = 50

  private var stateKey: String {
    [
      selectedTask.taskId,
      tasks.map(\.taskId).joined(separator: ","),
      agents.map(\.agentId).joined(separator: ","),
    ].joined(separator: "|")
  }

  var body: some View {
    InspectorTaskActionsSection(
      task: selectedTask,
      tasks: tasks,
      agents: agents,
      taskID: $taskID,
      assigneeID: $assigneeID,
      taskStatus: $taskStatus,
      statusNote: $statusNote,
      checkpointSummary: $checkpointSummary,
      checkpointProgress: $checkpointProgress,
      isSessionReadOnly: isSessionReadOnly,
      isSessionActionInFlight: isSessionActionInFlight,
      assignSelectedTask: submitAssignSelectedTask,
      updateSelectedTask: submitUpdateSelectedTask,
      checkpointSelectedTask: submitCheckpointSelectedTask
    )
    .task(id: stateKey) {
      syncDefaults()
    }
  }

  private func syncDefaults() {
    taskID = selectedTask.taskId
    taskStatus = selectedTask.status

    if let assignedAgentID = selectedTask.assignedTo,
      agents.contains(where: { $0.agentId == assignedAgentID }) {
      assigneeID = assignedAgentID
    } else if !agents.contains(where: { $0.agentId == assigneeID }) {
      assigneeID = agents.first?.agentId ?? ""
    }

    if let checkpoint = selectedTask.checkpointSummary {
      checkpointProgress = Double(checkpoint.progress)
    }
  }

  private func submitAssignSelectedTask() {
    Task { await assignSelectedTask() }
  }

  private func submitUpdateSelectedTask() {
    Task { await updateSelectedTask() }
  }

  private func submitCheckpointSelectedTask() {
    Task { await checkpointSelectedTask() }
  }

  private func assignSelectedTask() async {
    guard !taskID.isEmpty, !assigneeID.isEmpty else {
      return
    }

    _ = await assignTaskAction(taskID, assigneeID)
    syncDefaults()
  }

  private func updateSelectedTask() async {
    guard !taskID.isEmpty else {
      return
    }

    let note = statusNote.trimmingCharacters(in: .whitespacesAndNewlines)
    let success = await updateTaskStatusAction(
      taskID,
      taskStatus,
      note.isEmpty ? nil : note
    )
    if success {
      statusNote = ""
    }
    syncDefaults()
  }

  private func checkpointSelectedTask() async {
    let summary = checkpointSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !taskID.isEmpty, !summary.isEmpty else {
      return
    }

    let success = await checkpointTaskAction(taskID, summary, Int(checkpointProgress))
    if success {
      checkpointSummary = ""
    }
    syncDefaults()
  }
}

struct InspectorRoleMutationConsole: View {
  let selectedAgent: AgentRegistration
  let leaderID: String?
  let isSessionReadOnly: Bool
  let isSessionActionInFlight: Bool
  let changeRoleAction: (String, SessionRole) async -> Bool
  let requestRemoveAgentConfirmation: (String) -> Void

  @State private var role: SessionRole = .worker

  private var stateKey: String {
    "\(selectedAgent.agentId)|\(selectedAgent.role.rawValue)|\(leaderID ?? "-")"
  }

  var body: some View {
    InspectorRoleActionsSection(
      agent: selectedAgent,
      leaderID: leaderID,
      role: $role,
      isSessionReadOnly: isSessionReadOnly,
      isSessionActionInFlight: isSessionActionInFlight,
      changeSelectedRole: submitChangeSelectedRole,
      requestRemoveAgentConfirmation: requestRemoveAgentConfirmation
    )
    .task(id: stateKey) {
      role = selectedAgent.role
    }
  }

  private func submitChangeSelectedRole() {
    Task { await changeSelectedRole() }
  }

  private func changeSelectedRole() async {
    _ = await changeRoleAction(selectedAgent.agentId, role)
    role = selectedAgent.role
  }
}

struct InspectorLeaderTransferConsole: View {
  let detail: SessionDetail
  let actionActorID: String
  let isSessionReadOnly: Bool
  let isSessionActionInFlight: Bool
  let transferLeaderAction: (String, String?) async -> Bool

  @State private var transferLeaderID = ""
  @State private var transferReason = ""

  private var stateKey: String {
    [
      detail.session.sessionId,
      detail.agents.map(\.agentId).joined(separator: ","),
      detail.session.pendingLeaderTransfer?.newLeaderId ?? "-",
      actionActorID,
    ].joined(separator: "|")
  }

  private var transferLeaderButtonTitle: String {
    if detail.session.pendingLeaderTransfer != nil,
      actionActorID == detail.session.leaderId {
      return "Confirm Leadership Transfer"
    }
    return "Transfer Leadership"
  }

  var body: some View {
    InspectorLeaderTransferSection(
      detail: detail,
      transferLeaderID: $transferLeaderID,
      transferReason: $transferReason,
      transferLeaderButtonTitle: transferLeaderButtonTitle,
      actionActorID: actionActorID,
      isSessionReadOnly: isSessionReadOnly,
      isSessionActionInFlight: isSessionActionInFlight,
      submitTransferLeader: submitTransferLeader
    )
    .task(id: stateKey) {
      syncDefaults()
    }
  }

  private func syncDefaults() {
    if let pendingLeaderID = detail.session.pendingLeaderTransfer?.newLeaderId,
      detail.agents.contains(where: { $0.agentId == pendingLeaderID }) {
      transferLeaderID = pendingLeaderID
      return
    }

    if transferLeaderID.isEmpty || !detail.agents.contains(where: { $0.agentId == transferLeaderID }) {
      transferLeaderID = detail.agents.first?.agentId ?? ""
    }
  }

  private func submitTransferLeader() {
    Task { await transferLeader() }
  }

  private func transferLeader() async {
    let reason = transferReason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !transferLeaderID.isEmpty else {
      return
    }

    let success = await transferLeaderAction(
      transferLeaderID,
      reason.isEmpty ? nil : reason
    )
    if success {
      transferReason = ""
    }
    syncDefaults()
  }
}
