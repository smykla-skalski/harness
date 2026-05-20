import Foundation
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
  @State private var submitForReviewSummary = ""
  @State private var reviewActorID = ""
  @State private var reviewVerdict: ReviewVerdict = .approve
  @State private var reviewSummary = ""
  @State private var reviewPointText = ""
  @State private var reviewResponseNote = ""
  @State private var disputedReviewPointIDs: Set<String> = []
  @State private var arbitrationVerdict: ReviewVerdict = .approve
  @State private var arbitrationSummary = ""

  private var detail: SessionDetail? {
    store.contentUI.sessionDetail.presentedSessionDetail
  }

  private var task: WorkItem? { detail?.tasks.first { $0.taskId == taskID } }

  private var tasks: [WorkItem] { detail?.tasks ?? [] }
  private var agents: [AgentRegistration] { detail?.agents ?? [] }
  private var assignmentAgents: [AgentRegistration] { Self.eligibleAssignmentAgents(agents) }

  private var areSessionActionsAvailable: Bool { store.areSelectedSessionActionsAvailable }

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
      availableAgentIDs: assignmentAgents.map(\.agentId)
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
      if let banner = store.selectedSessionActionUnavailableMessage {
        Text(banner)
          .scaledFont(.system(.footnote, design: .rounded, weight: .medium))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      ReviewStatePanel(task: task)
      pickers(for: task)
      assignAndQueueRow(for: task)
      statusRow(for: task)
      Divider()
      reviewWorkflowSection(for: task)
      Divider()
      checkpointSection(for: task)
    }
  }

  private func pickers(for task: WorkItem) -> some View {
    TaskActionsPickerSection(
      task: task,
      tasks: tasks,
      assignmentAgents: assignmentAgents,
      taskSelection: taskSelection,
      assigneeSelection: assigneeSelection,
      taskStatus: $taskStatus,
      queuePolicy: $queuePolicy
    )
  }

  private func assignAndQueueRow(for task: WorkItem) -> some View {
    TaskActionsAssignmentRows(
      task: task,
      sessionID: sessionID,
      store: store,
      areSessionActionsAvailable: areSessionActionsAvailable,
      assignmentUnavailableMessage: assignmentUnavailableMessage(for: task),
      taskMutationUnavailableMessage: genericTaskMutationUnavailableMessage(for: task),
      submitAssign: submitAssign,
      submitUpdateQueuePolicy: submitUpdateQueuePolicy
    )
  }

  private func statusRow(for task: WorkItem) -> some View {
    TaskActionsStatusRow(
      task: task,
      sessionID: sessionID,
      store: store,
      areSessionActionsAvailable: areSessionActionsAvailable,
      taskMutationUnavailableMessage: genericTaskMutationUnavailableMessage(for: task),
      statusNote: $statusNote,
      submitUpdateStatus: submitUpdateStatus
    )
  }

  private func reviewWorkflowSection(for task: WorkItem) -> some View {
    TaskActionsReviewWorkflowSection(
      task: task,
      agents: agents,
      sessionID: sessionID,
      leaderID: detail?.session.leaderId,
      store: store,
      areSessionActionsAvailable: areSessionActionsAvailable,
      submitForReviewSummary: $submitForReviewSummary,
      reviewActorID: $reviewActorID,
      reviewVerdict: $reviewVerdict,
      reviewSummary: $reviewSummary,
      reviewPointText: $reviewPointText,
      reviewResponseNote: $reviewResponseNote,
      disputedReviewPointIDs: $disputedReviewPointIDs,
      arbitrationVerdict: $arbitrationVerdict,
      arbitrationSummary: $arbitrationSummary,
      submitForReview: submitSubmitForReview,
      claimReview: submitClaimReview,
      submitReview: submitSubmitReview,
      respondReview: submitRespondReview,
      arbitrate: submitArbitrate
    )
  }

  private func checkpointSection(for task: WorkItem) -> some View {
    TaskActionsCheckpointSection(
      task: task,
      sessionID: sessionID,
      store: store,
      areSessionActionsAvailable: areSessionActionsAvailable,
      taskMutationUnavailableMessage: genericTaskMutationUnavailableMessage(for: task),
      checkpointSummary: $checkpointSummary,
      checkpointProgress: $checkpointProgress,
      submitCheckpoint: submitCheckpoint
    )
  }

  private var unavailableState: some View { TaskActionsUnavailableState(dismiss: { dismiss() }) }

  private func assignmentUnavailableMessage(for task: WorkItem) -> String? {
    if let reviewMessage = genericTaskMutationUnavailableMessage(for: task) {
      return reviewMessage
    }
    guard task.status == .open else {
      return "Only open tasks can be assigned"
    }
    guard !effectiveAssigneeID.isEmpty else {
      return "No free worker is available"
    }
    return nil
  }

  private func genericTaskMutationUnavailableMessage(for task: WorkItem) -> String? {
    if task.status.isReviewManagedStatus {
      return "Use the review controls for this task"
    }
    if Self.isArbitrationBlocked(task) {
      return "This task is waiting for leader arbitration"
    }
    return nil
  }

  private func syncDefaults() {
    guard let task else { return }
    localTaskID = task.taskId
    taskStatus = task.status
    queuePolicy = task.queuePolicy
    if let assignedAgentID = task.assignedTo,
      assignmentAgents.contains(where: { $0.agentId == assignedAgentID })
    {
      assigneeID = assignedAgentID
    } else if assigneeID.isEmpty
      || !assignmentAgents.contains(where: { $0.agentId == assigneeID })
    {
      assigneeID = assignmentAgents.first?.agentId ?? ""
    }
    if let checkpoint = task.checkpointSummary {
      checkpointProgress = Double(checkpoint.progress)
    }
    disputedReviewPointIDs.formIntersection(Set(task.consensus?.points.map(\.pointId) ?? []))
  }

  private func submitAssign() { Task { await assign() } }

  private func submitUpdateStatus() { Task { await updateStatus() } }

  private func submitUpdateQueuePolicy() { Task { await updateQueuePolicy() } }

  private func submitCheckpoint() { Task { await checkpoint() } }

  private func submitSubmitForReview() { Task { await submitForReview() } }

  private func submitClaimReview() { Task { await claimReview() } }

  private func submitSubmitReview() { Task { await submitReview() } }

  private func submitRespondReview() { Task { await respondReview() } }

  private func submitArbitrate() { Task { await arbitrate() } }

  private func assign() async {
    guard !effectiveTaskID.isEmpty, !effectiveAssigneeID.isEmpty else { return }
    await TaskActionsSheetRequests.assign(
      store: store,
      taskID: effectiveTaskID,
      assigneeID: effectiveAssigneeID
    )
    syncDefaults()
  }

  private func updateStatus() async {
    guard !effectiveTaskID.isEmpty else { return }
    let success = await TaskActionsSheetRequests.updateStatus(
      store: store,
      taskID: effectiveTaskID,
      status: taskStatus,
      note: statusNote.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    if success { statusNote = "" }
    syncDefaults()
  }

  private func updateQueuePolicy() async {
    guard !effectiveTaskID.isEmpty else { return }
    await TaskActionsSheetRequests.updateQueuePolicy(
      store: store,
      taskID: effectiveTaskID,
      queuePolicy: queuePolicy
    )
    syncDefaults()
  }

  private func checkpoint() async {
    let summary = checkpointSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !effectiveTaskID.isEmpty, !summary.isEmpty else { return }
    let success = await TaskActionsSheetRequests.checkpoint(
      store: store,
      taskID: effectiveTaskID,
      summary: summary,
      progress: Int(checkpointProgress)
    )
    if success { checkpointSummary = "" }
    syncDefaults()
  }

  private func submitForReview() async {
    guard let task,
      let actorID = Self.submitForReviewActorID(for: task, agents: agents)
    else { return }
    let success = await TaskActionsSheetRequests.submitForReview(
      store: store,
      taskID: task.taskId,
      summary: submitForReviewSummary.trimmingCharacters(in: .whitespacesAndNewlines),
      actorID: actorID
    )
    if success { submitForReviewSummary = "" }
    syncDefaults()
  }

  private func claimReview() async {
    guard let task else { return }
    let candidates = Self.eligibleReviewClaimAgents(task: task, agents: agents)
    let actorID = Self.normalizedAgentID(
      draftID: reviewActorID,
      availableAgentIDs: candidates.map(\.agentId)
    )
    guard !actorID.isEmpty else { return }
    await TaskActionsSheetRequests.claimReview(
      store: store,
      taskID: task.taskId,
      actorID: actorID
    )
    reviewActorID = actorID
    syncDefaults()
  }

  private func submitReview() async {
    guard let task else { return }
    let candidates = Self.eligibleReviewSubmitAgents(task: task, agents: agents)
    let actorID = Self.normalizedAgentID(
      draftID: reviewActorID,
      availableAgentIDs: candidates.map(\.agentId)
    )
    let summary = reviewSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !actorID.isEmpty, !summary.isEmpty else { return }
    let success = await TaskActionsSheetRequests.submitReview(
      store: store,
      taskID: task.taskId,
      request: TaskActionsReviewSubmission(
        verdict: reviewVerdict,
        summary: summary,
        pointText: reviewPointText.trimmingCharacters(in: .whitespacesAndNewlines),
        actorID: actorID
      )
    )
    if success {
      reviewSummary = ""
      reviewPointText = ""
    }
    reviewActorID = actorID
    syncDefaults()
  }

  private func respondReview() async {
    guard let task,
      let actorID = Self.respondReviewActorID(for: task, agents: agents),
      let consensus = task.consensus
    else { return }
    let knownPointIDs = Set(consensus.points.map(\.pointId))
    let disputed = disputedReviewPointIDs.intersection(knownPointIDs).sorted()
    let agreed = consensus.points.map(\.pointId).filter { !disputed.contains($0) }
    let success = await TaskActionsSheetRequests.respondReview(
      store: store,
      taskID: task.taskId,
      response: TaskActionsReviewResponse(
        agreed: agreed,
        disputed: disputed,
        note: reviewResponseNote.trimmingCharacters(in: .whitespacesAndNewlines),
        actorID: actorID
      )
    )
    if success {
      reviewResponseNote = ""
      disputedReviewPointIDs.removeAll()
    }
    syncDefaults()
  }

  private func arbitrate() async {
    guard let task,
      let actorID = Self.arbitrationActorID(
        for: task,
        leaderID: detail?.session.leaderId,
        agents: agents
      )
    else { return }
    let summary = arbitrationSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !summary.isEmpty else { return }
    let success = await TaskActionsSheetRequests.arbitrate(
      store: store,
      taskID: task.taskId,
      verdict: arbitrationVerdict,
      summary: summary,
      actorID: actorID
    )
    if success { arbitrationSummary = "" }
    syncDefaults()
  }
}
