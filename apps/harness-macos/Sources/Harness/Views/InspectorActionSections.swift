import HarnessKit
import SwiftUI

struct InspectorActionSections: View {
  let detail: SessionDetail
  let selectedTask: WorkItem?
  let selectedAgent: AgentRegistration?
  let selectedObserver: ObserverSummary?
  let isSessionActionInFlight: Bool
  let lastAction: String
  let lastError: String?
  let availableActionActors: [AgentRegistration]
  @Binding var actionActorID: String
  let requestRemoveAgentConfirmation: (String) -> Void
  let createTaskAction: (String, String?, TaskSeverity) async -> Bool
  let assignTaskAction: (String, String) async -> Bool
  let updateTaskStatusAction: (String, TaskStatus, String?) async -> Bool
  let checkpointTaskAction: (String, String, Int) async -> Bool
  let changeRoleAction: (String, SessionRole) async -> Bool
  let transferLeaderAction: (String, String?) async -> Bool

  @State private var createTitle = ""
  @State private var createContext = ""
  @State private var createSeverity: TaskSeverity = .medium
  @State private var taskID = ""
  @State private var assigneeID = ""
  @State private var taskStatus: TaskStatus = .inProgress
  @State private var statusNote = ""
  @State private var checkpointSummary = ""
  @State private var checkpointProgress: Double = 50
  @State private var role: SessionRole = .worker
  @State private var transferLeaderID = ""
  @State private var transferReason = ""

  private var selectionKey: String {
    [
      detail.session.sessionId,
      selectedTask?.taskId ?? "-",
      selectedAgent?.agentId ?? "-",
      selectedObserver?.observeId ?? "-",
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
    VStack(alignment: .leading, spacing: 16) {
      InspectorActionStatusBanner(
        isSessionActionInFlight: isSessionActionInFlight,
        lastAction: lastAction,
        lastError: lastError,
        availableActionActors: availableActionActors,
        actionActorID: $actionActorID
      )
      InspectorCreateTaskSection(
        createTitle: $createTitle,
        createContext: $createContext,
        createSeverity: $createSeverity,
        isSessionActionInFlight: isSessionActionInFlight,
        submitCreateTask: submitCreateTask
      )

      if let selectedTask {
        InspectorTaskActionsSection(
          task: selectedTask,
          tasks: detail.tasks,
          agents: detail.agents,
          taskID: $taskID,
          assigneeID: $assigneeID,
          taskStatus: $taskStatus,
          statusNote: $statusNote,
          checkpointSummary: $checkpointSummary,
          checkpointProgress: $checkpointProgress,
          isSessionActionInFlight: isSessionActionInFlight,
          assignSelectedTask: submitAssignSelectedTask,
          updateSelectedTask: submitUpdateSelectedTask,
          checkpointSelectedTask: submitCheckpointSelectedTask
        )
      }

      if let selectedAgent {
        InspectorRoleActionsSection(
          agent: selectedAgent,
          leaderID: detail.session.leaderId,
          role: $role,
          isSessionActionInFlight: isSessionActionInFlight,
          changeSelectedRole: submitChangeSelectedRole,
          requestRemoveAgentConfirmation: requestRemoveAgentConfirmation
        )
      }

      InspectorLeaderTransferSection(
        detail: detail,
        transferLeaderID: $transferLeaderID,
        transferReason: $transferReason,
        transferLeaderButtonTitle: transferLeaderButtonTitle,
        actionActorID: actionActorID,
        isSessionActionInFlight: isSessionActionInFlight,
        submitTransferLeader: submitTransferLeader
      )

      if let selectedObserver {
        InspectorObserverSummarySection(observer: selectedObserver)
      }
    }
    .textFieldStyle(.roundedBorder)
    .task(id: selectionKey) {
      configureDefaults()
    }
  }
}

private extension InspectorActionSections {
  func configureDefaults() {
    if let selectedTask {
      taskID = selectedTask.taskId
    } else if taskID.isEmpty || !detail.tasks.contains(where: { $0.taskId == taskID }) {
      taskID = detail.tasks.first?.taskId ?? ""
    }

    if let selectedAgent {
      assigneeID = selectedAgent.agentId
      role = selectedAgent.role
    } else if assigneeID.isEmpty || !detail.agents.contains(where: { $0.agentId == assigneeID }) {
      assigneeID = detail.agents.first?.agentId ?? ""
    }

    let missingLeader = !detail.agents.contains(where: { $0.agentId == transferLeaderID })
    if transferLeaderID.isEmpty || missingLeader {
      transferLeaderID = detail.agents.first?.agentId ?? ""
    }

    let actorValid = availableActionActors.contains(where: { $0.agentId == actionActorID })
    if actionActorID.isEmpty || !actorValid {
      actionActorID = availableActionActors.first?.agentId ?? detail.session.leaderId ?? ""
    }
  }

  func submitCreateTask() {
    Task { await createTask() }
  }

  func submitAssignSelectedTask() {
    Task { await assignSelectedTask() }
  }

  func submitUpdateSelectedTask() {
    Task { await updateSelectedTask() }
  }

  func submitCheckpointSelectedTask() {
    Task { await checkpointSelectedTask() }
  }

  func submitChangeSelectedRole() {
    Task { await changeSelectedRole() }
  }

  func submitTransferLeader() {
    Task { await transferLeader() }
  }

  func createTask() async {
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
    configureDefaults()
  }

  func assignSelectedTask() async {
    guard !taskID.isEmpty, !assigneeID.isEmpty else {
      return
    }

    _ = await assignTaskAction(taskID, assigneeID)
    configureDefaults()
  }

  func updateSelectedTask() async {
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
    configureDefaults()
  }

  func checkpointSelectedTask() async {
    let summary = checkpointSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !taskID.isEmpty, !summary.isEmpty else {
      return
    }

    let success = await checkpointTaskAction(taskID, summary, Int(checkpointProgress))
    if success {
      checkpointSummary = ""
    }
    configureDefaults()
  }

  func changeSelectedRole() async {
    guard let agentID = selectedAgent?.agentId else {
      return
    }

    _ = await changeRoleAction(agentID, role)
    configureDefaults()
  }

  func transferLeader() async {
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
    configureDefaults()
  }
}
