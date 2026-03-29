import HarnessMonitorKit
import Observation
import SwiftUI

struct InspectorActionSections: View {
  @Bindable var store: MonitorStore
  let detail: SessionDetail
  let selectedTask: WorkItem?
  let selectedAgent: AgentRegistration?
  let selectedObserver: ObserverSummary?

  @State private var createTitle = ""
  @State private var createContext = ""
  @State private var createSeverity: TaskSeverity = .medium
  @State private var taskID = ""
  @State private var assigneeID = ""
  @State private var taskStatus: TaskStatus = .inProgress
  @State private var statusNote = ""
  @State private var checkpointSummary = ""
  @State private var checkpointProgress = 50
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

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      statusBanner
      sessionTaskActions

      if let selectedTask {
        taskActions(task: selectedTask)
      }

      if let selectedAgent {
        roleActions(agent: selectedAgent)
      }

      leaderActions

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
extension InspectorActionSections {
  fileprivate var statusBanner: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Action Console", systemImage: "dial.high")
          .font(.system(.headline, design: .rounded, weight: .semibold))
        Spacer()
        if store.isSessionActionInFlight {
          MonitorSpinner()
        } else if !store.lastAction.isEmpty {
          Text(store.lastAction)
            .font(.caption.bold())
            .foregroundStyle(MonitorTheme.success)
        }
      }
      Text(
        "Task creation, reassignments, checkpoints, and leadership changes flow through the daemon."
      )
      .font(.system(.footnote, design: .rounded, weight: .medium))
      .foregroundStyle(MonitorTheme.secondaryInk)
      if !store.availableActionActors.isEmpty {
        Picker("Act As", selection: actionActorBinding) {
          ForEach(store.availableActionActors) { agent in
            Text(agent.name).tag(agent.agentId)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel("Act As")
        .accessibilityIdentifier(MonitorAccessibility.actionActorPicker)
      }
      if let error = store.lastError {
        Text(error)
          .font(.system(.footnote, design: .rounded, weight: .semibold))
          .foregroundStyle(MonitorTheme.danger)
      }
    }
    .monitorCard()
  }
  fileprivate func taskActions(task: WorkItem) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      monitorActionHeader(
        title: "Task Actions",
        subtitle: "Reassign, update status, or checkpoint the selected task."
      )
      Picker("Task", selection: $taskID) {
        ForEach(detail.tasks) { item in
          Text(item.title).tag(item.taskId)
        }
      }
      Picker("Assignee", selection: $assigneeID) {
        ForEach(detail.agents) { agent in
          Text(agent.name).tag(agent.agentId)
        }
      }
      Picker("Status", selection: $taskStatus) {
        ForEach(TaskStatus.allCases, id: \.self) { status in
          Text(status.title).tag(status)
        }
      }
      HStack {
        Button("Assign") {
          Task { await assignSelectedTask() }
        }
        .monitorActionButtonStyle(variant: .prominent, tint: MonitorTheme.accent)
      }
      HStack {
        Button("Update Status") {
          Task { await updateSelectedTask() }
        }
        .monitorActionButtonStyle(variant: .bordered, tint: MonitorTheme.ink)
        TextField("Update note", text: $statusNote, axis: .vertical)
          .lineLimit(2, reservesSpace: true)
      }

      Divider()

      Text("Checkpoint")
        .font(.headline)
      TextField("Summary", text: $checkpointSummary, axis: .vertical)
        .lineLimit(3, reservesSpace: true)
      Slider(value: checkpointBinding, in: 0...100, step: 5)
      HStack {
        Text("\(checkpointProgress)%")
          .font(.caption.bold())
          .foregroundStyle(MonitorTheme.secondaryInk)
        Spacer()
        Button("Save Checkpoint") {
          Task { await checkpointSelectedTask() }
        }
        .monitorActionButtonStyle(variant: .prominent, tint: MonitorTheme.warmAccent)
      }

      if let checkpoint = task.checkpointSummary {
        Text("Latest: \(checkpoint.progress)% · \(checkpoint.summary)")
          .font(.caption)
          .foregroundStyle(MonitorTheme.secondaryInk)
      }
    }
    .monitorCard()
  }
  fileprivate var sessionTaskActions: some View {
    VStack(alignment: .leading, spacing: 12) {
      monitorActionHeader(
        title: "Create Task",
        subtitle: "Capture new work directly into the active session."
      )
      TextField("Title", text: $createTitle)
      TextField("Context", text: $createContext, axis: .vertical)
        .lineLimit(4, reservesSpace: true)
      Picker("Severity", selection: $createSeverity) {
        ForEach(TaskSeverity.allCases, id: \.self) { severity in
          Text(severity.title).tag(severity)
        }
      }
      Button("Create Task") {
        Task { await createTask() }
      }
      .monitorActionButtonStyle(variant: .prominent, tint: MonitorTheme.accent)
      .disabled(createTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .monitorCard()
  }
  fileprivate func roleActions(agent: AgentRegistration) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      monitorActionHeader(
        title: "Role Actions",
        subtitle: "Change the selected agent role without leaving the inspector."
      )
      Text(agent.name)
        .font(.system(.headline, design: .rounded, weight: .semibold))
      Picker("Role", selection: $role) {
        ForEach(SessionRole.allCases.filter { $0 != .leader }, id: \.self) { role in
          Text(role.title).tag(role)
        }
      }
      Button("Change Role") {
        Task { await changeSelectedRole() }
      }
      .monitorActionButtonStyle(variant: .prominent, tint: MonitorTheme.accent)
      Button("Remove Agent") {
        store.requestRemoveAgentConfirmation(agentID: agent.agentId)
      }
      .monitorActionButtonStyle(variant: .bordered, tint: MonitorTheme.danger)
      .disabled(agent.agentId == detail.session.leaderId)
      .accessibilityIdentifier(MonitorAccessibility.removeAgentButton)
    }
    .monitorCard()
  }
  fileprivate var leaderActions: some View {
    VStack(alignment: .leading, spacing: 12) {
      monitorActionHeader(
        title: "Leader Transfer",
        subtitle: "Promote a live agent to leader when the current leader needs to step away."
      )
      if let pendingTransfer = detail.session.pendingLeaderTransfer {
        let timestamp = formatTimestamp(pendingTransfer.requestedAt)
        Text(
          "\(pendingTransfer.requestedBy) requested \(pendingTransfer.newLeaderId) at \(timestamp)."
        )
        .font(.caption)
        .foregroundStyle(MonitorTheme.secondaryInk)
      }
      Picker("New Leader", selection: $transferLeaderID) {
        ForEach(detail.agents) { agent in
          Text(agent.name).tag(agent.agentId)
        }
      }
      TextField("Reason", text: $transferReason, axis: .vertical)
        .lineLimit(3, reservesSpace: true)
      Button(transferLeaderButtonTitle) {
        Task { await transferLeader() }
      }
      .monitorActionButtonStyle(variant: .prominent, tint: MonitorTheme.warmAccent)
      .disabled(transferLeaderID.isEmpty || transferLeaderID == detail.session.leaderId)
    }
    .monitorCard()
  }
  fileprivate var checkpointBinding: Binding<Double> {
    Binding(
      get: { Double(checkpointProgress) },
      set: { checkpointProgress = Int($0) }
    )
  }
  fileprivate func configureDefaults() {
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
  }
  fileprivate func createTask() async {
    let title = createTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let context = createContext.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      return
    }

    await store.createTask(
      title: title,
      context: context.isEmpty ? nil : context,
      severity: createSeverity
    )
    createTitle = ""
    createContext = ""
    createSeverity = .medium
    configureDefaults()
  }
  fileprivate func assignSelectedTask() async {
    guard !taskID.isEmpty, !assigneeID.isEmpty else {
      return
    }

    await store.assignTask(taskID: taskID, agentID: assigneeID)
    configureDefaults()
  }
  fileprivate func updateSelectedTask() async {
    guard !taskID.isEmpty else {
      return
    }

    let note = statusNote.trimmingCharacters(in: .whitespacesAndNewlines)
    await store.updateTaskStatus(
      taskID: taskID,
      status: taskStatus,
      note: note.isEmpty ? nil : note
    )
    statusNote = ""
    configureDefaults()
  }
  fileprivate func checkpointSelectedTask() async {
    let summary = checkpointSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !taskID.isEmpty, !summary.isEmpty else {
      return
    }

    await store.checkpointTask(
      taskID: taskID,
      summary: summary,
      progress: checkpointProgress
    )
    checkpointSummary = ""
    configureDefaults()
  }
  fileprivate func changeSelectedRole() async {
    guard let agentID = selectedAgent?.agentId else {
      return
    }

    await store.changeRole(agentID: agentID, role: role)
    configureDefaults()
  }
  fileprivate func transferLeader() async {
    let reason = transferReason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !transferLeaderID.isEmpty else {
      return
    }

    await store.transferLeader(
      newLeaderID: transferLeaderID,
      reason: reason.isEmpty ? nil : reason
    )
    transferReason = ""
    configureDefaults()
  }

  fileprivate var actionActorBinding: Binding<String> {
    Binding(
      get: {
        store.actionActorID
          ?? store.availableActionActors.first?.agentId
          ?? detail.session.leaderId
          ?? ""
      },
      set: { store.actionActorID = $0 }
    )
  }

  fileprivate var transferLeaderButtonTitle: String {
    let actingAgentID = store.actionActorID ?? detail.session.leaderId
    if detail.session.pendingLeaderTransfer != nil && actingAgentID == detail.session.leaderId {
      return "Confirm Leadership Transfer"
    }
    return "Transfer Leadership"
  }
}
