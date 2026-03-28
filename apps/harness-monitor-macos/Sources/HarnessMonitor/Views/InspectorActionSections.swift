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
        observerSummary(observer: selectedObserver)
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
        if store.isBusy {
          ProgressView()
            .controlSize(.small)
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
      .foregroundStyle(.secondary)
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
      actionHeader(
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
          Text(status.rawValue.capitalized).tag(status)
        }
      }
      HStack {
        Button("Assign") {
          Task { await assignSelectedTask() }
        }
        .buttonStyle(.borderedProminent)
        .tint(MonitorTheme.accent)
      }
      HStack {
        Button("Update Status") {
          Task { await updateSelectedTask() }
        }
        .buttonStyle(.bordered)
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
          .foregroundStyle(.secondary)
        Spacer()
        Button("Save Checkpoint") {
          Task { await checkpointSelectedTask() }
        }
        .buttonStyle(.borderedProminent)
        .tint(MonitorTheme.warmAccent)
      }

      if let checkpoint = task.checkpointSummary {
        Text("Latest: \(checkpoint.progress)% · \(checkpoint.summary)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .monitorCard()
  }

  fileprivate var sessionTaskActions: some View {
    VStack(alignment: .leading, spacing: 12) {
      actionHeader(
        title: "Create Task",
        subtitle: "Capture new work directly into the active session."
      )
      TextField("Title", text: $createTitle)
      TextField("Context", text: $createContext, axis: .vertical)
        .lineLimit(4, reservesSpace: true)
      Picker("Severity", selection: $createSeverity) {
        ForEach(TaskSeverity.allCases, id: \.self) { severity in
          Text(severity.rawValue.capitalized).tag(severity)
        }
      }
      Button("Create Task") {
        Task { await createTask() }
      }
      .buttonStyle(.borderedProminent)
      .tint(MonitorTheme.accent)
      .disabled(createTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .monitorCard()
  }

  fileprivate func roleActions(agent: AgentRegistration) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      actionHeader(
        title: "Role Actions",
        subtitle: "Change the selected agent role without leaving the inspector."
      )
      Text(agent.name)
        .font(.system(.headline, design: .rounded, weight: .semibold))
      Picker("Role", selection: $role) {
        ForEach(SessionRole.allCases, id: \.self) { role in
          Text(role.rawValue.capitalized).tag(role)
        }
      }
      Button("Change Role") {
        Task { await changeSelectedRole() }
      }
      .buttonStyle(.borderedProminent)
      .tint(MonitorTheme.accent)
    }
    .monitorCard()
  }

  fileprivate var leaderActions: some View {
    VStack(alignment: .leading, spacing: 12) {
      actionHeader(
        title: "Leader Transfer",
        subtitle: "Promote a live agent to leader when the current leader needs to step away."
      )
      Picker("New Leader", selection: $transferLeaderID) {
        ForEach(detail.agents) { agent in
          Text(agent.name).tag(agent.agentId)
        }
      }
      TextField("Reason", text: $transferReason, axis: .vertical)
        .lineLimit(3, reservesSpace: true)
      Button("Transfer Leadership") {
        Task { await transferLeader() }
      }
      .buttonStyle(.borderedProminent)
      .tint(MonitorTheme.warmAccent)
      .disabled(transferLeaderID.isEmpty)
    }
    .monitorCard()
  }
  fileprivate func actionHeader(title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.system(.headline, design: .rounded, weight: .semibold))
      Text(subtitle)
        .font(.system(.subheadline, design: .rounded, weight: .medium))
        .foregroundStyle(.secondary)
    }
  }

  fileprivate func badge(_ value: String) -> some View {
    Text(value)
      .font(.caption.bold())
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(Color.white.opacity(0.68), in: Capsule())
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
}
