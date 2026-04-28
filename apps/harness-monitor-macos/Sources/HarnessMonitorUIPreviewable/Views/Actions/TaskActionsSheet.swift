import HarnessMonitorKit
import SwiftUI

struct TaskActionsSheet: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let taskID: String
  @Environment(\.dismiss)
  private var dismiss

  @State private var localTaskID = ""
  @State private var assigneeID = ""
  @State private var taskStatus: TaskStatus = .inProgress
  @State private var queuePolicy: TaskQueuePolicy = .locked
  @State private var statusNote = ""
  @State private var checkpointSummary = ""
  @State private var checkpointProgress: Double = 50

  private var detail: SessionDetail? {
    store.contentUI.sessionDetail.presentedSessionDetail
  }

  private var task: WorkItem? {
    detail?.tasks.first { $0.taskId == taskID }
  }

  private var tasks: [WorkItem] { detail?.tasks ?? [] }
  private var agents: [AgentRegistration] { detail?.agents ?? [] }

  private var areSessionActionsAvailable: Bool {
    store.areSelectedSessionActionsAvailable
  }
  private var effectiveTaskID: String {
    Self.normalizedTaskID(
      draftID: localTaskID,
      currentTaskID: task?.taskId,
      availableTaskIDs: tasks.map(\.taskId)
    )
  }
  private var effectiveAssigneeID: String {
    Self.normalizedAssigneeID(
      draftID: assigneeID,
      assignedAgentID: task?.assignedTo,
      availableAgentIDs: agents.map(\.agentId)
    )
  }
  private var taskSelection: Binding<String> {
    Binding(
      get: { effectiveTaskID },
      set: { localTaskID = $0 }
    )
  }
  private var assigneeSelection: Binding<String> {
    Binding(
      get: { effectiveAssigneeID },
      set: { assigneeID = $0 }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let task {
        header(for: task)
        Divider()
        ScrollView {
          form(for: task)
            .padding(HarnessMonitorTheme.spacingLG)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!areSessionActionsAvailable)
        }
      } else {
        unavailableState
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.taskActionsSheet)
    .onAppear { syncDefaults() }
    .onChange(of: task == nil) { _, missing in
      if missing { dismiss() }
    }
    .onChange(of: task?.status.rawValue) { _, _ in
      syncDefaults()
    }
  }

  private func header(for task: WorkItem) -> some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text("Task Actions")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Text(task.title)
          .scaledFont(.system(.title3, design: .rounded, weight: .bold))
      }
      Spacer()
      Button("Done") { dismiss() }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier(HarnessMonitorAccessibility.taskActionsSheetDismiss)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func form(for task: WorkItem) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      if let banner = store.selectedSessionActionBannerMessage {
        Text(banner)
          .scaledFont(.system(.footnote, design: .rounded, weight: .medium))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      ReviewStatePanel(task: task)
      pickers(for: task)
      assignAndQueueRow(for: task)
      statusRow(for: task)
      Divider()
      checkpointSection(for: task)
    }
  }

  @ViewBuilder
  private func pickers(for task: WorkItem) -> some View {
    Picker("Task", selection: taskSelection) {
      ForEach(tasks) { item in
        Text(item.title).tag(item.taskId)
      }
    }
    .harnessNativeFormControl()
    Picker("Assignee", selection: assigneeSelection) {
      ForEach(agents) { agent in
        Text(agent.name).tag(agent.agentId)
      }
    }
    .harnessNativeFormControl()
    if task.status.isReviewManagedStatus {
      LabeledContent("Status") {
        Text(task.status.title)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Text("Review status changes are managed by the review flow.")
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    } else {
      Picker("Status", selection: $taskStatus) {
        ForEach(TaskStatus.genericStatusChoices, id: \.self) { status in
          Text(status.title).tag(status)
        }
      }
      .harnessNativeFormControl()
    }
    Picker("Queue Policy", selection: $queuePolicy) {
      ForEach(TaskQueuePolicy.allCases, id: \.self) { policy in
        Text(policy.title).tag(policy)
      }
    }
    .harnessNativeFormControl()
  }

  private func assignAndQueueRow(for task: WorkItem) -> some View {
    HStack {
      HarnessInlineActionButton(
        title: "Assign",
        actionID: .assignTask(sessionID: sessionID, taskID: task.taskId),
        store: store,
        variant: .prominent,
        tint: nil,
        isExternallyDisabled: !areSessionActionsAvailable,
        accessibilityIdentifier: HarnessMonitorAccessibility.assignTaskButton,
        action: submitAssign
      )
      HarnessInlineActionButton(
        title: "Save Queue Policy",
        actionID: .updateTaskQueuePolicy(sessionID: sessionID, taskID: task.taskId),
        store: store,
        variant: .bordered,
        tint: .secondary,
        isExternallyDisabled: !areSessionActionsAvailable,
        accessibilityIdentifier: HarnessMonitorAccessibility.updateTaskQueuePolicyButton,
        action: submitUpdateQueuePolicy
      )
    }
  }

  @ViewBuilder
  private func statusRow(for task: WorkItem) -> some View {
    if task.status.isReviewManagedStatus {
      Text("Status updates are unavailable while the task is in the review flow.")
        .scaledFont(.footnote)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    } else {
      HStack {
        HarnessInlineActionButton(
          title: "Update Status",
          actionID: .updateTaskStatus(sessionID: sessionID, taskID: task.taskId),
          store: store,
          variant: .bordered,
          tint: .secondary,
          isExternallyDisabled: !areSessionActionsAvailable,
          accessibilityIdentifier: HarnessMonitorAccessibility.updateTaskStatusButton,
          action: submitUpdateStatus
        )
        TextField("Update note", text: $statusNote, axis: .vertical)
          .harnessNativeFormControl()
          .lineLimit(2, reservesSpace: true)
          .submitLabel(.done)
      }
    }
  }

  @ViewBuilder
  private func checkpointSection(for task: WorkItem) -> some View {
    Text("Checkpoint")
      .scaledFont(.headline)
    TextField("Summary", text: $checkpointSummary, axis: .vertical)
      .harnessNativeFormControl()
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
        action: submitCheckpoint
      )
    }
    if let checkpoint = task.checkpointSummary {
      Text("Latest: \(checkpoint.progress)% · \(checkpoint.summary)")
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }

  private var unavailableState: some View {
    VStack(spacing: HarnessMonitorTheme.spacingMD) {
      Image(systemName: "questionmark.circle")
        .font(.system(size: 36))
        .foregroundStyle(.secondary)
      Text("Task unavailable.")
        .scaledFont(.headline)
      Button("Dismiss") { dismiss() }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier(HarnessMonitorAccessibility.taskActionsSheetDismiss)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func syncDefaults() {
    guard let task else { return }
    localTaskID = task.taskId
    taskStatus = task.status
    queuePolicy = task.queuePolicy
    if let assignedAgentID = task.assignedTo,
      agents.contains(where: { $0.agentId == assignedAgentID })
    {
      assigneeID = assignedAgentID
    } else if assigneeID.isEmpty || !agents.contains(where: { $0.agentId == assigneeID }) {
      assigneeID = agents.first?.agentId ?? ""
    }
    if let checkpoint = task.checkpointSummary {
      checkpointProgress = Double(checkpoint.progress)
    }
  }

  private func submitAssign() {
    Task { await assign() }
  }

  private func submitUpdateStatus() {
    Task { await updateStatus() }
  }

  private func submitUpdateQueuePolicy() {
    Task { await updateQueuePolicy() }
  }

  private func submitCheckpoint() {
    Task { await checkpoint() }
  }

  private func assign() async {
    guard !effectiveTaskID.isEmpty, !effectiveAssigneeID.isEmpty else { return }
    _ = await store.assignTask(taskID: effectiveTaskID, agentID: effectiveAssigneeID)
    syncDefaults()
  }

  private func updateStatus() async {
    guard !effectiveTaskID.isEmpty else { return }
    let note = statusNote.trimmingCharacters(in: .whitespacesAndNewlines)
    let success = await store.updateTaskStatus(
      taskID: effectiveTaskID,
      status: taskStatus,
      note: note.isEmpty ? nil : note
    )
    if success { statusNote = "" }
    syncDefaults()
  }

  private func updateQueuePolicy() async {
    guard !effectiveTaskID.isEmpty else { return }
    _ = await store.updateTaskQueuePolicy(taskID: effectiveTaskID, queuePolicy: queuePolicy)
    syncDefaults()
  }

  private func checkpoint() async {
    let summary = checkpointSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !effectiveTaskID.isEmpty, !summary.isEmpty else { return }
    let success = await store.checkpointTask(
      taskID: effectiveTaskID,
      summary: summary,
      progress: Int(checkpointProgress)
    )
    if success { checkpointSummary = "" }
    syncDefaults()
  }

  static func normalizedTaskID(
    draftID: String,
    currentTaskID: String?,
    availableTaskIDs: [String]
  ) -> String {
    if let currentTaskID, availableTaskIDs.contains(currentTaskID) {
      return currentTaskID
    }
    if availableTaskIDs.contains(draftID) {
      return draftID
    }
    return availableTaskIDs.first ?? ""
  }

  static func normalizedAssigneeID(
    draftID: String,
    assignedAgentID: String?,
    availableAgentIDs: [String]
  ) -> String {
    if availableAgentIDs.contains(draftID) {
      return draftID
    }
    if let assignedAgentID, availableAgentIDs.contains(assignedAgentID) {
      return assignedAgentID
    }
    return availableAgentIDs.first ?? ""
  }
}

#Preview("Task actions sheet") {
  TaskActionsSheet(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    sessionID: PreviewFixtures.summary.sessionId,
    taskID: PreviewFixtures.tasks[0].taskId
  )
  .frame(width: 520, height: 620)
}
