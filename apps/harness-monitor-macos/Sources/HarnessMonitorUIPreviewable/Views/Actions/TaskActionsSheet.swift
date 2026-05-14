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

  private var task: WorkItem? {
    detail?.tasks.first { $0.taskId == taskID }
  }

  private var tasks: [WorkItem] { detail?.tasks ?? [] }
  private var agents: [AgentRegistration] { detail?.agents ?? [] }
  private var assignmentAgents: [AgentRegistration] {
    Self.eligibleAssignmentAgents(agents)
  }

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

  @ViewBuilder
  private func pickers(for task: WorkItem) -> some View {
    Picker("Task", selection: taskSelection) {
      ForEach(tasks) { item in
        Text(item.title).tag(item.taskId)
      }
    }
    .harnessNativeFormControl()
    if assignmentAgents.isEmpty {
      LabeledContent("Assignee") {
        Text("No free workers")
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    } else {
      Picker("Assignee", selection: assigneeSelection) {
        ForEach(assignmentAgents) { agent in
          Text(agent.name).tag(agent.agentId)
        }
      }
      .harnessNativeFormControl()
    }
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

  @ViewBuilder
  private func assignAndQueueRow(for task: WorkItem) -> some View {
    let assignmentHelp = assignmentUnavailableMessage(for: task) ?? ""
    let genericMutationHelp = genericTaskMutationUnavailableMessage(for: task) ?? ""
    HStack {
      HarnessInlineActionButton(
        title: "Assign",
        actionID: .assignTask(sessionID: sessionID, taskID: task.taskId),
        store: store,
        variant: .prominent,
        tint: nil,
        isExternallyDisabled:
          !areSessionActionsAvailable || assignmentUnavailableMessage(for: task) != nil,
        accessibilityIdentifier: HarnessMonitorAccessibility.assignTaskButton,
        help: assignmentHelp,
        action: submitAssign
      )
      HarnessInlineActionButton(
        title: "Save Queue Policy",
        actionID: .updateTaskQueuePolicy(sessionID: sessionID, taskID: task.taskId),
        store: store,
        variant: .bordered,
        tint: .secondary,
        isExternallyDisabled:
          !areSessionActionsAvailable || genericTaskMutationUnavailableMessage(for: task) != nil,
        accessibilityIdentifier: HarnessMonitorAccessibility.updateTaskQueuePolicyButton,
        help: genericMutationHelp,
        action: submitUpdateQueuePolicy
      )
    }
  }

  @ViewBuilder
  private func statusRow(for task: WorkItem) -> some View {
    if let message = genericTaskMutationUnavailableMessage(for: task) {
      Text("Status updates are unavailable while the task is in the review flow.")
        .scaledFont(.footnote)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(message)
        .scaledFont(.caption)
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
  private func reviewWorkflowSection(for task: WorkItem) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      Text("Review")
        .scaledFont(.headline)
      submitForReviewSection(for: task)
      claimReviewSection(for: task)
      submitReviewSection(for: task)
      respondReviewSection(for: task)
      arbitrateSection(for: task)
    }
  }

  @ViewBuilder
  private func submitForReviewSection(for task: WorkItem) -> some View {
    if task.status == .inProgress {
      let actorID = Self.submitForReviewActorID(for: task, agents: agents)
      TextField("Summary", text: $submitForReviewSummary, axis: .vertical)
        .harnessNativeFormControl()
        .lineLimit(2, reservesSpace: true)
        .submitLabel(.done)
      HarnessInlineActionButton(
        title: "Submit for Review",
        actionID: .submitTaskForReview(sessionID: sessionID, taskID: task.taskId),
        store: store,
        variant: .prominent,
        tint: nil,
        isExternallyDisabled: !areSessionActionsAvailable || actorID == nil,
        accessibilityIdentifier: HarnessMonitorAccessibility.submitTaskForReviewButton,
        help: actorID == nil ? "Only the assigned worker can submit this task for review." : "",
        action: submitSubmitForReview
      )
    }
  }

  @ViewBuilder
  private func claimReviewSection(for task: WorkItem) -> some View {
    let candidates = Self.eligibleReviewClaimAgents(task: task, agents: agents)
    if matchesReviewQueueStatus(task) {
      if !candidates.isEmpty {
        Picker("Claim As", selection: reviewActorSelection(candidates: candidates)) {
          ForEach(candidates) { agent in
            Text(agent.name).tag(agent.agentId)
          }
        }
        .harnessNativeFormControl()
      } else {
        Text("No eligible reviewer is available for this task.")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      HarnessInlineActionButton(
        title: "Claim Review",
        actionID: .claimTaskReview(sessionID: sessionID, taskID: task.taskId),
        store: store,
        variant: .bordered,
        tint: .secondary,
        isExternallyDisabled: !areSessionActionsAvailable || candidates.isEmpty,
        accessibilityIdentifier: HarnessMonitorAccessibility.claimTaskReviewButton,
        help: candidates.isEmpty ? "No eligible reviewer is available for this task." : "",
        action: submitClaimReview
      )
    }
  }

  @ViewBuilder
  private func submitReviewSection(for task: WorkItem) -> some View {
    let candidates = Self.eligibleReviewSubmitAgents(task: task, agents: agents)
    let summary = reviewSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    if task.status == .inReview {
      if !candidates.isEmpty {
        Picker("Reviewing As", selection: reviewActorSelection(candidates: candidates)) {
          ForEach(candidates) { agent in
            Text(agent.name).tag(agent.agentId)
          }
        }
        .harnessNativeFormControl()
        Picker("Verdict", selection: $reviewVerdict) {
          ForEach(ReviewVerdict.allCases, id: \.self) { verdict in
            Text(verdict.title).tag(verdict)
          }
        }
        .harnessNativeFormControl()
        TextField("Review summary", text: $reviewSummary, axis: .vertical)
          .harnessNativeFormControl()
          .lineLimit(2, reservesSpace: true)
          .submitLabel(.done)
        TextField("Review point", text: $reviewPointText, axis: .vertical)
          .harnessNativeFormControl()
          .lineLimit(2, reservesSpace: true)
          .submitLabel(.done)
      } else {
        Text("A claimed reviewer is required before submitting review.")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      HarnessInlineActionButton(
        title: "Submit Review",
        actionID: .submitTaskReview(sessionID: sessionID, taskID: task.taskId),
        store: store,
        variant: .prominent,
        tint: nil,
        isExternallyDisabled:
          !areSessionActionsAvailable
          || candidates.isEmpty
          || summary.isEmpty,
        accessibilityIdentifier: HarnessMonitorAccessibility.submitTaskReviewButton,
        help: submitReviewUnavailableMessage(candidates: candidates, summary: summary),
        action: submitSubmitReview
      )
    }
  }

  @ViewBuilder
  private func respondReviewSection(for task: WorkItem) -> some View {
    let points = task.consensus?.points ?? []
    let actorID = Self.respondReviewActorID(for: task, agents: agents)
    if Self.shouldShowReviewResponse(for: task) {
      if points.isEmpty {
        Text("Consensus has no review points to dispute.")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      } else {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          ForEach(points) { point in
            Toggle(isOn: disputeBinding(for: point.pointId)) {
              Text(point.text)
                .lineLimit(2)
            }
            .toggleStyle(.checkbox)
          }
        }
      }
      TextField("Response note", text: $reviewResponseNote, axis: .vertical)
        .harnessNativeFormControl()
        .lineLimit(2, reservesSpace: true)
        .submitLabel(.done)
      HarnessInlineActionButton(
        title: "Respond to Review",
        actionID: .respondTaskReview(sessionID: sessionID, taskID: task.taskId),
        store: store,
        variant: .bordered,
        tint: .secondary,
        isExternallyDisabled: !areSessionActionsAvailable || actorID == nil,
        accessibilityIdentifier: HarnessMonitorAccessibility.respondTaskReviewButton,
        help: actorID == nil ? "Only the original worker can respond to consensus." : "",
        action: submitRespondReview
      )
    }
  }

  @ViewBuilder
  private func arbitrateSection(for task: WorkItem) -> some View {
    let actorID = Self.arbitrationActorID(
      for: task,
      leaderID: detail?.session.leaderId,
      agents: agents
    )
    if Self.isArbitrationBlocked(task) {
      Picker("Arbitration Verdict", selection: $arbitrationVerdict) {
        ForEach(ReviewVerdict.allCases, id: \.self) { verdict in
          Text(verdict.title).tag(verdict)
        }
      }
      .harnessNativeFormControl()
      TextField("Arbitration summary", text: $arbitrationSummary, axis: .vertical)
        .harnessNativeFormControl()
        .lineLimit(2, reservesSpace: true)
        .submitLabel(.done)
      HarnessInlineActionButton(
        title: "Arbitrate",
        actionID: .arbitrateTask(sessionID: sessionID, taskID: task.taskId),
        store: store,
        variant: .prominent,
        tint: HarnessMonitorTheme.caution,
        isExternallyDisabled:
          !areSessionActionsAvailable
          || actorID == nil
          || arbitrationSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        accessibilityIdentifier: HarnessMonitorAccessibility.arbitrateTaskButton,
        help: arbitrationUnavailableMessage(actorID: actorID),
        action: submitArbitrate
      )
    }
  }

  @ViewBuilder
  private func checkpointSection(for task: WorkItem) -> some View {
    let unavailableMessage = genericTaskMutationUnavailableMessage(for: task)
    let checkpointSummaryValue = checkpointSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    let checkpointUnavailableMessage =
      unavailableMessage
      ?? (checkpointSummaryValue.isEmpty ? "Checkpoint summary is required." : nil)
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
        isExternallyDisabled:
          !areSessionActionsAvailable || checkpointUnavailableMessage != nil,
        accessibilityIdentifier: HarnessMonitorAccessibility.checkpointTaskButton,
        help: checkpointUnavailableMessage ?? "",
        action: submitCheckpoint
      )
    }
    if let checkpointUnavailableMessage {
      Text(checkpointUnavailableMessage)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
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

  private func matchesReviewQueueStatus(_ task: WorkItem) -> Bool {
    task.status == .awaitingReview || task.status == .inReview
  }

  private func reviewActorSelection(candidates: [AgentRegistration]) -> Binding<String> {
    Binding(
      get: {
        Self.normalizedAgentID(
          draftID: reviewActorID,
          availableAgentIDs: candidates.map(\.agentId)
        )
      },
      set: { reviewActorID = $0 }
    )
  }

  private func disputeBinding(for pointID: String) -> Binding<Bool> {
    Binding(
      get: { disputedReviewPointIDs.contains(pointID) },
      set: { isDisputed in
        if isDisputed {
          disputedReviewPointIDs.insert(pointID)
        } else {
          disputedReviewPointIDs.remove(pointID)
        }
      }
    )
  }

  private func assignmentUnavailableMessage(for task: WorkItem) -> String? {
    if let reviewMessage = genericTaskMutationUnavailableMessage(for: task) {
      return reviewMessage
    }
    guard task.status == .open else {
      return "Only open tasks can be assigned."
    }
    guard !effectiveAssigneeID.isEmpty else {
      return "No free worker is available."
    }
    return nil
  }

  private func genericTaskMutationUnavailableMessage(for task: WorkItem) -> String? {
    if task.status.isReviewManagedStatus {
      return "Use the review controls for this task."
    }
    if Self.isArbitrationBlocked(task) {
      return "This task is waiting for leader arbitration."
    }
    return nil
  }

  private func submitReviewUnavailableMessage(
    candidates: [AgentRegistration],
    summary: String
  ) -> String {
    if candidates.isEmpty {
      return "A reviewer must claim this task before submitting review."
    }
    if summary.isEmpty {
      return "Review summary is required."
    }
    return ""
  }

  private func arbitrationUnavailableMessage(actorID: String?) -> String {
    if actorID == nil {
      return "Only the current leader can arbitrate this task."
    }
    if arbitrationSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Arbitration summary is required."
    }
    return ""
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

  private func submitSubmitForReview() {
    Task { await submitForReview() }
  }

  private func submitClaimReview() {
    Task { await claimReview() }
  }

  private func submitSubmitReview() {
    Task { await submitReview() }
  }

  private func submitRespondReview() {
    Task { await respondReview() }
  }

  private func submitArbitrate() {
    Task { await arbitrate() }
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

  private func submitForReview() async {
    guard let task,
      let actorID = Self.submitForReviewActorID(for: task, agents: agents)
    else { return }
    let summary = submitForReviewSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    let success = await store.submitTaskForReview(
      taskID: task.taskId,
      summary: summary.isEmpty ? nil : summary,
      actor: actorID
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
    _ = await store.claimTaskReview(taskID: task.taskId, actor: actorID)
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
    let pointText = reviewPointText.trimmingCharacters(in: .whitespacesAndNewlines)
    let points =
      pointText.isEmpty
      ? []
      : [ReviewPoint(pointId: "monitor-\(UUID().uuidString)", text: pointText)]
    let success = await store.submitTaskReview(
      taskID: task.taskId,
      verdict: reviewVerdict,
      summary: summary,
      points: points,
      actor: actorID
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
    let note = reviewResponseNote.trimmingCharacters(in: .whitespacesAndNewlines)
    let success = await store.respondTaskReview(
      taskID: task.taskId,
      agreed: agreed,
      disputed: disputed,
      note: note.isEmpty ? nil : note,
      actor: actorID
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
    let success = await store.arbitrateTask(
      taskID: task.taskId,
      verdict: arbitrationVerdict,
      summary: summary,
      actor: actorID
    )
    if success { arbitrationSummary = "" }
    syncDefaults()
  }

  nonisolated static func eligibleAssignmentAgents(
    _ agents: [AgentRegistration]
  ) -> [AgentRegistration] {
    agents.filter { agent in
      agent.role == .worker
        && matchesAssignmentStatus(agent.status)
        && agent.currentTaskId == nil
    }
  }

  nonisolated static func eligibleReviewClaimAgents(
    task: WorkItem,
    agents: [AgentRegistration]
  ) -> [AgentRegistration] {
    guard task.status == .awaitingReview || task.status == .inReview else { return [] }
    let claimedRuntimes = Set(task.reviewClaim?.reviewers.map(\.reviewerRuntime) ?? [])
    return agents.filter { agent in
      (agent.role == .reviewer || agent.role == .leader)
        && matchesAliveStatus(agent.status)
        && !claimedRuntimes.contains(agent.runtime)
    }
  }

  nonisolated static func eligibleReviewSubmitAgents(
    task: WorkItem,
    agents: [AgentRegistration]
  ) -> [AgentRegistration] {
    guard task.status == .inReview else { return [] }
    let claimedAgentIDs = Set(task.reviewClaim?.reviewers.map(\.reviewerAgentId) ?? [])
    return agents.filter { agent in
      claimedAgentIDs.contains(agent.agentId) && matchesAliveStatus(agent.status)
    }
  }

  nonisolated static func submitForReviewActorID(
    for task: WorkItem,
    agents: [AgentRegistration]
  ) -> String? {
    guard task.status == .inProgress,
      let assignedTo = task.assignedTo,
      let agent = agents.first(where: { $0.agentId == assignedTo }),
      agent.role == .worker,
      matchesAliveStatus(agent.status)
    else {
      return nil
    }
    return assignedTo
  }

  nonisolated static func respondReviewActorID(
    for task: WorkItem,
    agents: [AgentRegistration]
  ) -> String? {
    guard task.status == .inReview,
      task.consensus != nil,
      let submitterID = task.awaitingReview?.submitterAgentId,
      let agent = agents.first(where: { $0.agentId == submitterID }),
      matchesAliveStatus(agent.status)
    else {
      return nil
    }
    return submitterID
  }

  nonisolated static func shouldShowReviewResponse(for task: WorkItem) -> Bool {
    task.status == .inReview && task.consensus != nil
  }

  nonisolated static func arbitrationActorID(
    for task: WorkItem,
    leaderID: String?,
    agents: [AgentRegistration]
  ) -> String? {
    guard isArbitrationBlocked(task),
      let leaderID,
      let leader = agents.first(where: { $0.agentId == leaderID }),
      matchesAliveStatus(leader.status)
    else {
      return nil
    }
    return leaderID
  }

  nonisolated static func isArbitrationBlocked(_ task: WorkItem) -> Bool {
    task.status == .blocked
      && task.blockedReason == "awaiting_arbitration"
      && task.reviewRound >= 3
  }

  nonisolated static func normalizedAgentID(
    draftID: String,
    availableAgentIDs: [String]
  ) -> String {
    if availableAgentIDs.contains(draftID) {
      return draftID
    }
    return availableAgentIDs.first ?? ""
  }

  nonisolated private static func matchesAliveStatus(_ status: AgentStatus) -> Bool {
    switch status {
    case .active, .idle, .awaitingReview:
      true
    case .disconnected, .removed:
      false
    }
  }

  nonisolated private static func matchesAssignmentStatus(_ status: AgentStatus) -> Bool {
    switch status {
    case .active, .idle:
      true
    case .awaitingReview, .disconnected, .removed:
      false
    }
  }

  nonisolated static func normalizedTaskID(
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

  nonisolated static func normalizedAssigneeID(
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
