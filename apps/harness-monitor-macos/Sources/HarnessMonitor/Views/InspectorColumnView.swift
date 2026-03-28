import HarnessMonitorKit
import Observation
import SwiftUI

struct InspectorColumnView: View {
  @Bindable var store: MonitorStore
  @Bindable var actions: CockpitActionCenter
  @State private var signalCommand = "inject_context"
  @State private var signalMessage = ""
  @State private var signalActionHint = ""

  private var selectedObserver: ObserverSummary? {
    guard case .observer = store.inspectorSelection else {
      return nil
    }
    return store.selectedSession?.observer
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if let task = store.selectedTask {
          taskInspector(task)
        } else if let agent = store.selectedAgent {
          agentInspector(agent)
        } else if let signal = store.selectedSignal {
          signalInspector(signal)
        } else if let observer = selectedObserver {
          observerInspector(observer)
        } else if let detail = store.selectedSession {
          sessionInspector(detail)
        } else {
          emptyState
        }
        if let detail = store.selectedSession {
          InspectorActionSections(
            store: store,
            actions: actions,
            detail: detail,
            selectedTask: store.selectedTask,
            selectedAgent: store.selectedAgent,
            selectedObserver: selectedObserver
          )
        }
      }
      .padding(22)
    }
    .background(MonitorTheme.canvas.ignoresSafeArea())
    .foregroundStyle(MonitorTheme.ink)
  }

  private func sessionInspector(_ detail: SessionDetail) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Inspector")
        .font(.system(.title3, design: .serif, weight: .semibold))
      Text(
        "Pick a task, agent, signal, or observe card from the cockpit to focus actions and detail here."
      )
      .foregroundStyle(.secondary)
      HStack {
        keyValue("Leader", detail.session.leaderId ?? "n/a")
        keyValue("Last Activity", formatTimestamp(detail.session.lastActivityAt))
      }
    }
    .monitorCard()
  }

  private func taskInspector(_ task: WorkItem) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(task.title)
        .font(.system(.title3, design: .serif, weight: .bold))
      Text(task.context ?? "No task context provided.")
        .foregroundStyle(.secondary)
      keyValue("Severity", task.severity.rawValue.capitalized)
      keyValue("Status", task.status.rawValue.capitalized)
      keyValue("Assignee", task.assignedTo ?? "Unassigned")
      if let checkpoint = task.checkpointSummary {
        keyValue("Checkpoint", "\(checkpoint.progress)% • \(checkpoint.summary)")
      }
      if let suggestion = task.suggestedFix {
        Text("Suggested Fix")
          .font(.headline)
        Text(suggestion)
          .foregroundStyle(.secondary)
      }
    }
    .monitorCard()
  }

  private func agentInspector(_ agent: AgentRegistration) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(agent.name)
        .font(.system(.title3, design: .serif, weight: .bold))
      Text("\(agent.runtime) • \(agent.role.rawValue.capitalized)")
        .foregroundStyle(.secondary)
      keyValue("Current Task", agent.currentTaskId ?? "Idle")
      keyValue("Last Activity", formatTimestamp(agent.lastActivityAt))
      keyValue(
        "Signal Pickup",
        "\(agent.runtimeCapabilities.typicalSignalLatencySeconds)s typical"
      )
      Text("Send Signal")
        .font(.headline)
      TextField("Command", text: $signalCommand)
      TextField("Message", text: $signalMessage, axis: .vertical)
        .lineLimit(3, reservesSpace: true)
      TextField("Action Hint", text: $signalActionHint)
      Button("Send") {
        Task {
          await store.sendSignal(
            agentID: agent.agentId,
            command: signalCommand,
            message: signalMessage,
            actionHint: signalActionHint.isEmpty ? nil : signalActionHint
          )
        }
      }
      .buttonStyle(.borderedProminent)
      .tint(MonitorTheme.accent)
      .disabled(signalCommand.isEmpty || signalMessage.isEmpty)
    }
    .textFieldStyle(.roundedBorder)
    .monitorCard()
  }

  private func signalInspector(_ signal: SessionSignalRecord) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(signal.signal.command)
        .font(.system(.title3, design: .serif, weight: .bold))
      Text(signal.signal.payload.message)
        .foregroundStyle(.secondary)
      keyValue("Status", signal.status.rawValue.capitalized)
      keyValue("Agent", signal.agentId)
      keyValue("Priority", signal.signal.priority.rawValue.capitalized)
      keyValue("Created", formatTimestamp(signal.signal.createdAt))
      if let acknowledgment = signal.acknowledgment {
        keyValue("Acknowledged", acknowledgment.result.rawValue.capitalized)
        if let details = acknowledgment.details {
          Text(details)
            .foregroundStyle(.secondary)
        }
      }
    }
    .monitorCard()
  }

  private func observerInspector(_ observer: ObserverSummary) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Observe")
        .font(.system(.title3, design: .serif, weight: .bold))
      keyValue("Observer", observer.observeId)
      keyValue("Open Issues", "\(observer.openIssueCount)")
      keyValue("Muted Codes", "\(observer.mutedCodeCount)")
      keyValue("Active Workers", "\(observer.activeWorkerCount)")
      keyValue("Last Sweep", formatTimestamp(observer.lastScanTime))
    }
    .monitorCard()
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Inspector")
        .font(.system(.title3, design: .serif, weight: .semibold))
      Text("Select a session to inspect live task, agent, and signal detail.")
        .foregroundStyle(.secondary)
    }
    .monitorCard()
  }

  private func keyValue(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.body, design: .rounded, weight: .semibold))
    }
  }
}

struct InspectorActionSections: View {
  @Bindable var store: MonitorStore
  @Bindable var actions: CockpitActionCenter
  let detail: SessionDetail
  let selectedTask: WorkItem?
  let selectedAgent: AgentRegistration?
  let selectedObserver: ObserverSummary?

  @State var createTitle = ""
  @State var createContext = ""
  @State var createSeverity: TaskSeverity = .medium
  @State var taskID = ""
  @State var assigneeID = ""
  @State var taskStatus: TaskStatus = .inProgress
  @State var statusNote = ""
  @State var checkpointSummary = ""
  @State var checkpointProgress = 50
  @State var role: SessionRole = .worker
  @State var roleReason = ""
  @State var transferLeaderID = ""
  @State var transferReason = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      statusBanner

      if let selectedTask {
        taskActions(task: selectedTask)
      } else {
        sessionTaskActions
        if let selectedAgent {
          roleActions(agent: selectedAgent)
        } else {
          leaderActions
        }
      }

      if let selectedObserver {
        observerSummary(observer: selectedObserver)
      }
    }
    .textFieldStyle(.roundedBorder)
    .task {
      configureDefaults()
    }
  }
}

extension InspectorActionSections {
  var statusBanner: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Action Console", systemImage: "dial.high")
          .font(.system(.headline, design: .rounded, weight: .semibold))
        Spacer()
        if actions.isBusy {
          ProgressView()
            .controlSize(.small)
        } else if !actions.lastAction.isEmpty {
          Text(actions.lastAction)
            .font(.caption.bold())
            .foregroundStyle(MonitorTheme.success)
        }
      }
      Text(
        "Task creation, reassignments, checkpoints, and leadership changes flow through the daemon."
      )
      .font(.system(.footnote, design: .rounded, weight: .medium))
      .foregroundStyle(.secondary)
      if let error = actions.lastError {
        Text(error)
          .font(.system(.footnote, design: .rounded, weight: .semibold))
          .foregroundStyle(MonitorTheme.danger)
      }
    }
    .monitorCard()
  }

  func taskActions(task: WorkItem) -> some View {
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

  var sessionTaskActions: some View {
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

  func roleActions(agent: AgentRegistration) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      actionHeader(
        title: "Role Actions",
        subtitle: "Change the selected agent role or hand leadership to another agent."
      )
      Picker("Role", selection: $role) {
        ForEach(SessionRole.allCases, id: \.self) { role in
          Text(role.rawValue.capitalized).tag(role)
        }
      }
      TextField("Reason", text: $roleReason, axis: .vertical)
        .lineLimit(3, reservesSpace: true)
      Button("Change Role") {
        Task { await changeSelectedRole() }
      }
      .buttonStyle(.borderedProminent)
      .tint(MonitorTheme.accent)
      .disabled(agent.agentId.isEmpty)
    }
    .monitorCard()
  }

  var leaderActions: some View {
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

  func observerSummary(observer: ObserverSummary) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      actionHeader(
        title: "Observe",
        subtitle: "The observer loop keeps the session moving and surfaces drift."
      )
      HStack {
        badge("Open \(observer.openIssueCount)")
        badge("Muted \(observer.mutedCodeCount)")
        badge("Workers \(observer.activeWorkerCount)")
      }
      Text("Last sweep \(formatTimestamp(observer.lastScanTime))")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
    }
    .monitorCard()
  }

  func actionHeader(title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.system(.headline, design: .rounded, weight: .semibold))
      Text(subtitle)
        .font(.system(.subheadline, design: .rounded, weight: .medium))
        .foregroundStyle(.secondary)
    }
  }

  func badge(_ value: String) -> some View {
    Text(value)
      .font(.caption.bold())
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(Color.white.opacity(0.68), in: Capsule())
  }

  var checkpointBinding: Binding<Double> {
    Binding(
      get: { Double(checkpointProgress) },
      set: { checkpointProgress = Int($0) }
    )
  }

  func configureDefaults() {
    if taskID.isEmpty {
      taskID = selectedTask?.taskId ?? detail.tasks.first?.taskId ?? ""
    }
    if assigneeID.isEmpty {
      assigneeID = selectedAgent?.agentId ?? detail.agents.first?.agentId ?? ""
    }
    if transferLeaderID.isEmpty {
      transferLeaderID = detail.agents.first?.agentId ?? ""
    }
  }

  func createTask() async {
    let title = createTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let context = createContext.trimmingCharacters(in: .whitespacesAndNewlines)
    let payload = context.isEmpty ? nil : context
    guard !title.isEmpty else {
      return
    }

    if let updated = await actions.createTask(
      sessionID: detail.session.sessionId,
      title: title,
      context: payload,
      severity: createSeverity
    ) {
      await store.selectSession(updated.session.sessionId)
      createTitle = ""
      createContext = ""
      createSeverity = .medium
    }
  }

  func assignSelectedTask() async {
    guard !taskID.isEmpty, !assigneeID.isEmpty else {
      return
    }

    if let updated = await actions.assignTask(
      sessionID: detail.session.sessionId,
      taskID: taskID,
      agentID: assigneeID
    ) {
      await store.selectSession(updated.session.sessionId)
    }
  }

  func updateSelectedTask() async {
    guard !taskID.isEmpty else {
      return
    }

    if let updated = await actions.updateTask(
      sessionID: detail.session.sessionId,
      taskID: taskID,
      status: taskStatus,
      note: statusNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : statusNote
    ) {
      await store.selectSession(updated.session.sessionId)
      statusNote = ""
    }
  }

  func checkpointSelectedTask() async {
    guard !taskID.isEmpty else {
      return
    }

    let summary = checkpointSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !summary.isEmpty else {
      return
    }

    if let updated = await actions.checkpointTask(
      sessionID: detail.session.sessionId,
      taskID: taskID,
      summary: summary,
      progress: checkpointProgress
    ) {
      await store.selectSession(updated.session.sessionId)
      checkpointSummary = ""
    }
  }

  func changeSelectedRole() async {
    guard !assigneeID.isEmpty else {
      return
    }

    if let updated = await actions.changeRole(
      sessionID: detail.session.sessionId,
      agentID: assigneeID,
      role: role
    ) {
      await store.selectSession(updated.session.sessionId)
      roleReason = ""
    }
  }

  func transferLeader() async {
    let reason = transferReason.trimmingCharacters(in: .whitespacesAndNewlines)
    let payload = reason.isEmpty ? nil : reason
    guard !transferLeaderID.isEmpty else {
      return
    }

    if let updated = await actions.transferLeader(
      sessionID: detail.session.sessionId,
      newLeaderID: transferLeaderID,
      reason: payload
    ) {
      await store.selectSession(updated.session.sessionId)
      transferReason = ""
    }
  }
}
